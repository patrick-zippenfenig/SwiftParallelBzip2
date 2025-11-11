// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Synchronization
import Lbzip2
import NIOCore

public enum SwiftParallelBzip2Error: Error {
    case invalidBzip2Header
    case invalidStreamHeader
    case streamCRCMismatch
    case unexpectedEndOfStream
    case unexpectedParserError(UInt32)
    case unexpectedDecoderError(UInt32)
}

struct InputStream<T: AsyncSequence> where T.Element: DataProtocol {
    var inputItr: T.AsyncIterator
    var bitstream: bitstream
    var inputBuffer: ByteBuffer
    
    public init(input: T) {
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
    
    mutating func parseFileHeader() async throws -> Parser {
        guard let firstData = try await inputItr.next() else {
            throw SwiftParallelBzip2Error.unexpectedEndOfStream
        }
        inputBuffer.writeBytes(firstData)
        guard let head: Int32 = inputBuffer.readInteger() else {
            throw SwiftParallelBzip2Error.unexpectedEndOfStream
        }
        guard head >= 0x425A6830 + 1 && head <= 0x425A6830 + 9 else {
            throw SwiftParallelBzip2Error.invalidBzip2Header
        }
        let bs100k = head - 0x425A6830
        return Parser(bs100k: bs100k)
    }
    
    mutating func more() async throws {
        guard let next = try await inputItr.next() else {
            bitstream.eof = true
            return
        }
        inputBuffer.discardReadBytes()
        inputBuffer.writeBytes(next)
    }
}

func decode<T: AsyncSequence>(input: T) async throws where T.Element: DataProtocol {
    var inputStream = InputStream(input: input)
    var parser = try await inputStream.parseFileHeader()

    
    while true {
        guard let headerCrc = try await parser.parse(&inputStream) else {
            print("finished")
            return
        }
        
        let decoder = Decoder(headerCrc: headerCrc)
        while try await decoder.retrieve(&inputStream.inputBuffer, &inputStream.bitstream) {
            try await inputStream.more()
        }
        
        Task {
            decoder.decode()
            try decoder.emit()

        }
    }
}

extension InputStream {
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
                    var garbage: UInt32 = 0
                    let parserReturn = stream.inputBuffer.readWithUnsafeReadableBytes { ptr in
                        stream.bitstream.data = ptr.baseAddress?.assumingMemoryBound(to: UInt32.self)
                        stream.bitstream.limit = ptr.baseAddress?.advanced(by: ptr.count).assumingMemoryBound(to: UInt32.self)
                        let ret = Lbzip2.error(rawValue: UInt32(Lbzip2.parse(&parser, &header, &stream.bitstream, &garbage)))
                        let bytesRead = ptr.baseAddress?.distance(to: UnsafeRawPointer(stream.bitstream.data)) ?? 0
                        //print("parser bytesRead \(bytesRead)")
                        return (bytesRead, ret)
                    }
                    switch parserReturn {
                    case OK:
                        assert(garbage < 32)
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

final class Decoder {
    var decoder = decoder_state()
    var headerCrc: UInt32
    
    public init(headerCrc: UInt32) {
        decoder_init(&decoder)
        self.headerCrc = headerCrc
    }
    
    /// Return true until all data is available
    func retrieve(_ inputBuffer: inout ByteBuffer, _ bitstream: inout bitstream) async throws -> Bool {
        let ret = inputBuffer.readWithUnsafeReadableBytes { ptr in
            bitstream.data = ptr.baseAddress?.assumingMemoryBound(to: UInt32.self)
            bitstream.limit = ptr.baseAddress?.advanced(by: ptr.count).assumingMemoryBound(to: UInt32.self)
            //print("Bitstream IN \(bitstream.data!) \(bitstream.limit!)")
            let ret = Lbzip2.error(rawValue: UInt32(Lbzip2.retrieve(&decoder, &bitstream)))
            //print("Bitstream OUT \(bitstream.data!) \(bitstream.limit!)")
            let bytesRead = ptr.baseAddress?.distance(to: UnsafeRawPointer(bitstream.data)) ?? 0
            //print("retrieve bytesRead \(bytesRead)")
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
    
    func emit() throws {
        // Run Emit
        // Can also run in a different thread again and produces the uncompressed output
        
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(decoder.block_size), alignment: 0)
        var outsize: Int = output.count
        let emitRv = Lbzip2.emit(&decoder, output.baseAddress, &outsize)
        print(emitRv, outsize)
        // rv can be MORE to grow the output buffer
        print("Decoder CRC expected \(decoder.crc)")
        assert(decoder.crc == headerCrc)
        
        print(String(data: Data(output[0..<output.count - outsize]), encoding: .utf8))
    }
    
    deinit {
        decoder_free(&decoder)
    }
}

extension decoder_state: @retroactive @unchecked Sendable {
    
}

extension bitstream: @retroactive @unchecked Sendable {
    
}

