import Testing
@testable import SwiftParallelBzip2
import Foundation

@Test func example() async throws {
    
    let projectHome = String(#filePath[...#filePath.range(of: "/Sources/")!.lowerBound])
    FileManager.default.changeCurrentDirectoryPath(projectHome)
    
    let compressed = try Data(contentsOf: URL(fileURLWithPath: "test.txt.bz2"))
    print(compressed)
    
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
