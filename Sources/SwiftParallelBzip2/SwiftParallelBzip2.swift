import Foundation
import NIOCore
import AsyncAlgorithms

public enum SwiftParallelBzip2Error: Error {
    case invalidBzip2Header
    case invalidStreamHeader
    case streamCRCMismatch
    case blockCRCMismatch
    case unexpectedEndOfStream
    case unexpectedParserError(UInt32)
    case unexpectedDecoderError(UInt32)
}

extension AsyncSequence where Element: DataProtocol, Self: Sendable {
    public func decodeBzip2(bufferPolicy: AsyncBufferSequencePolicy = .bounded(10)) async throws -> AsyncThrowingMapSequence<AsyncBufferSequence<AsyncThrowingChannel<Task<ByteBuffer, any Error>, any Error>>, ByteBuffer> {
        let channel = AsyncThrowingChannel<Task<ByteBuffer, any Error>, Error>()
        Task {
            var inputStream = InputStream<Self>(input: self)
            do {
                var parser = try await inputStream.parseFileHeader()
                while true {
                    try Task.checkCancellation()
                    guard let headerCrc = try await parser.parse(&inputStream) else {
                        channel.finish()
                        return
                    }
                    
                    let decoder = Decoder(headerCrc: headerCrc)
                    while try await decoder.retrieve(&inputStream.inputBuffer, &inputStream.bitstream) {
                        try await inputStream.more()
                    }
                    await channel.send(Task {
                        await decoder.decode()
                        return try await decoder.emit()
                    })
                }
            } catch {
                channel.fail(error)
            }
        }
        let result = channel.buffer(policy: bufferPolicy).map { task in
            try await task.value
        }
        return result
    }
}

