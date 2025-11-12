import Foundation
import Lbzip2
import NIOCore

/// Wrap AsyncSequence iterator, ByteBuffer and bitstream
struct InputStream<T: AsyncSequence> where T.Element == ByteBuffer {
    var base: T
    var inputItr: T.AsyncIterator
    var bitstream: bitstream
    var inputBuffer: ByteBuffer
    
    public init(input: T) {
        self.base = input
        self.inputItr = input.makeAsyncIterator()
        self.bitstream = Lbzip2.bitstream()
        self.inputBuffer = ByteBuffer()
        
        bitstream.live = 0
        bitstream.buff = 0
        bitstream.block = nil
        bitstream.data = nil
        bitstream.limit = nil
        bitstream.eof = false
    }
    
    mutating func more() async throws {
        guard let next = try await inputItr.next() else {
            bitstream.eof = true
            return
        }
        inputBuffer = consume next
        
        // make sure to align readable bytes to 4 bytes
        let remaining = inputBuffer.readableBytes % 4
        if remaining != 0 {
            inputBuffer.writeRepeatingByte(0, count: 4-remaining)
        }
    }
}


extension InputStream {
    mutating func parseFileHeader() async throws -> Parser {
        guard var firstData = try await inputItr.next() else {
            throw SwiftParallelBzip2Error.unexpectedEndOfStream
        }
        inputBuffer.writeBuffer(&firstData)
        guard let head: Int32 = inputBuffer.readInteger() else {
            throw SwiftParallelBzip2Error.unexpectedEndOfStream
        }
        guard head >= 0x425A6830 + 1 && head <= 0x425A6830 + 9 else {
            throw SwiftParallelBzip2Error.invalidBzip2Header
        }
        let bs100k = head - 0x425A6830
        return Parser(bs100k: bs100k)
    }
    
    struct Parser {
        var parser: parser_state = parser_state()
        
        init(bs100k: Int32) {
            parser_init(&parser, bs100k, 0)
        }
        
        mutating func parse(_ stream: inout InputStream) async throws -> UInt32? {
            /* Parse stream headers until a compressed block or end of stream is reached.

               Possible return codes:
                 OK          - a compressed block was found
                 FINISH      - end of stream was reached
                 MORE        - more input is need, parsing was suspended
                 ERR_HEADER  - invalid stream header
                 ERR_STRMCRC - stream CRC does not match
                 ERR_EOF     - unterminated stream (EOF reached before end of stream)

               garbage is set only when returning FINISH.  It is number of garbage bits
               consumed after end of stream was reached.
            */
            while true {
                var header = header()
                parserLoop: while true {
                    let parserReturn = stream.inputBuffer.readWithUnsafeReadableBytes { ptr in
                        stream.bitstream.data = ptr.baseAddress?.assumingMemoryBound(to: UInt32.self)
                        stream.bitstream.limit = ptr.baseAddress?.advanced(by: ptr.count).assumingMemoryBound(to: UInt32.self)
                        var garbage: UInt32 = 0
                        let ret = Lbzip2.error(rawValue: UInt32(Lbzip2.parse(&parser, &header, &stream.bitstream, &garbage)))
                        assert(garbage < 32)
                        assert(stream.bitstream.data <= stream.bitstream.limit)
                        let bytesRead = ptr.baseAddress?.distance(to: UnsafeRawPointer(stream.bitstream.data)) ?? 0
                        //print("parser bytesRead \(bytesRead)")
                        return (bytesRead, ret)
                    }
                    switch parserReturn {
                    case OK:
                        return header.crc
                    case FINISH:
                        return nil
                    case MORE:
                        try await stream.more()
                        continue
                    case ERR_HEADER:
                        throw SwiftParallelBzip2Error.invalidStreamHeader
                    case ERR_STRMCRC:
                        throw SwiftParallelBzip2Error.streamCRCMismatch
                    case ERR_EOF:
                        throw SwiftParallelBzip2Error.streamCRCMismatch
                    default:
                        throw SwiftParallelBzip2Error.unexpectedParserError(parserReturn.rawValue)
                    }
                }
            }
        }
    }
}

final actor Decoder {
    var decoder = decoder_state()
    let headerCrc: UInt32
    let bs100k: Int32
    
    public init(headerCrc: UInt32, bs100k: Int32) {
        decoder_init(&decoder)
        self.headerCrc = headerCrc
        self.bs100k = bs100k
    }
    
    /// Return true until all data is available
    func retrieve(_ inputBuffer: inout ByteBuffer, _ bitstream: inout bitstream) async throws -> Bool {
        let ret = inputBuffer.readWithUnsafeReadableBytes { ptr in
            bitstream.data = ptr.baseAddress?.assumingMemoryBound(to: UInt32.self)
            bitstream.limit = ptr.baseAddress?.advanced(by: ptr.count).assumingMemoryBound(to: UInt32.self)
            //print("Bitstream IN \(bitstream.data!) \(bitstream.limit!)")
            let ret = Lbzip2.error(rawValue: UInt32(Lbzip2.retrieve(&decoder, &bitstream)))
            assert(bitstream.data <= bitstream.limit)
            //print("Bitstream OUT \(bitstream.data!) \(bitstream.limit!)")
            let bytesRead = ptr.baseAddress?.distance(to: UnsafeRawPointer(bitstream.data)) ?? 0
            //print("retrieve bytesRead \(bytesRead) ret=\(ret)")
            return (bytesRead, ret)
        }
        switch ret {
        case Lbzip2.OK:
            return false
        case Lbzip2.MORE:
            return true
        default:
            throw SwiftParallelBzip2Error.unexpectedDecoderError(ret.rawValue)
        }
    }
    
    func decode() {
        // Decode can now run in a different thread
        // Decoder does not need buffered input data anymore
        Lbzip2.decode(&decoder)
    }
    
    func emit() throws -> ByteBuffer {
        var out = ByteBuffer()
        // Reserve the maximum output block size
        out.writeWithUnsafeMutableBytes(minimumWritableBytes: Int(bs100k*100_000)) { ptr in
            var outsize: Int = ptr.count
            guard Lbzip2.emit(&decoder, ptr.baseAddress, &outsize) == Lbzip2.OK.rawValue else {
                // Emit should not fail because enough output capacity is available
                fatalError("emit failed")
            }
            return ptr.count - outsize
        }
        guard decoder.crc == headerCrc else {
            throw SwiftParallelBzip2Error.blockCRCMismatch
        }
        //print("emit \(out.readableBytes) bytes")
        return out
    }
    
    deinit {
        decoder_free(&decoder)
    }
}

extension decoder_state: @retroactive @unchecked Sendable {
    
}

extension bitstream: @retroactive @unchecked Sendable {
    
}

