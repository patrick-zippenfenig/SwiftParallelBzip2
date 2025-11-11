import Testing
@testable import SwiftParallelBzip2
import Foundation

@Test func example() async throws {
    // Hello World\n
    let compressed = Data([66, 90, 104, 57, 49, 65, 89, 38, 83, 89, 216, 114, 1, 47, 0, 0, 1, 87, 128, 0, 16, 64, 0, 0, 64, 0, 128, 6, 4, 144, 0, 32, 0, 34, 6, 134, 212, 32, 201, 136, 199, 105, 232, 40, 31, 139, 185, 34, 156, 40, 72, 108, 57, 0, 151, 128])
    
    // turn to AsyncStream with chunks of 64kb
    let stream: AsyncStream<Data> = AsyncStream { continuation in
        let chunkSize = 8 //64 * 1024 // 64 KB
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + chunkSize, compressed.count)
            let range = offset..<end
            let chunk = compressed.subdata(in: range)
            continuation.yield(chunk)
            offset = end
        }
        continuation.finish()
    }
    try await decode(input: stream)
    
    sleep(1)
}
