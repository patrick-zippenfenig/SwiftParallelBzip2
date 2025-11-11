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
    /**
     Decode an bzip2 encoded stream of ByteBuffer to a stream of decoded blocks. Throws on invalid data.
     `bufferPolicy` can be used to limit buffering of decoded blocks. Defaults to 4 decoded blocks in the output channel
     */
    public func decodeBzip2(bufferPolicy: AsyncBufferSequencePolicy = .bounded(4)) async throws -> AsyncThrowingMapSequence<AsyncBufferSequence<AsyncThrowingChannel<Task<ByteBuffer, any Error>, any Error>>, ByteBuffer> {
        let worker = AsyncThrowingChannel<Task<ByteBuffer, any Error>, Error>()
        Task {
            var inputStream = InputStream<Self>(input: self)
            do {
                var parser = try await inputStream.parseFileHeader()
                while true {
                    try Task.checkCancellation()
                    guard let headerCrc = try await parser.parse(&inputStream) else {
                        worker.finish()
                        return
                    }
                    let decoder = Decoder(headerCrc: headerCrc)
                    while try await decoder.retrieve(&inputStream.inputBuffer, &inputStream.bitstream) {
                        try await inputStream.more()
                    }
                    await worker.send(Task {
                        await decoder.decode()
                        return try await decoder.emit()
                    })
                }
            } catch {
                worker.fail(error)
            }
        }
        // Limit the number of worker according to buffer policy
        return worker.buffer(policy: bufferPolicy).map { task in
            try await task.value
        }
    }
}

