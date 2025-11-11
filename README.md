# SwiftParallelBzip2
Parallel bzip2 decoding based on [lbzip2](https://github.com/kjn/lbzip2). Decoding is performed in C while parallel execution is handled by Swift Concurrency. Code is non-blocking and thread safe.

Currently, only supports decoding data! PRs welcome.


## Import Dependency

To use the `SwiftParallelBzip2` library in a SwiftPM project, 
add the following line to the dependencies in your `Package.swift` file:

```swift
.package(url: "https://github.com/patrick-zippenfenig
/SwiftParallelBzip2", from: "1.0.0"),
```

Include `"SwiftParallelBzip2"` as a dependency for your executable target:

```swift
.target(name: "<target>", dependencies: [
    .product(name: "SwiftParallelBzip2", package: "SwiftParallelBzip2"),
]),
```

Finally, add `import SwiftParallelBzip2` to your source code.


## Usage
Data must be provided as an AsyncSequence<ByteBuffer> and will be returned as AsyncSequence<ByteBuffer>. ByteBuffer is based on SwiftNIO.

Example:

```swift
import Testing
@testable import SwiftParallelBzip2
import Foundation
import NIOCore

@Test func example() async throws {
    // bzip2 encoded: Hello World\n
    let compressed = ByteBuffer(bytes: [66, 90, 104, 57, 49, 65, 89, 38, 83, 89, 216, 114, 1, 47, 0, 0, 1, 87, 128, 0, 16, 64, 0, 0, 64, 0, 128, 6, 4, 144, 0, 32, 0, 34, 6, 134, 212, 32, 201, 136, 199, 105, 232, 40, 31, 139, 185, 34, 156, 40, 72, 108, 57, 0, 151, 128])
    
    
    // turn to AsyncStream with chunks of 64kb
    let stream: AsyncStream<ByteBuffer> = AsyncStream { continuation in
        let chunkSize = 8 //64 * 1024 // 64 KB
        var offset = 0
        while offset < compressed.readableBytes {
            let end = min(offset + chunkSize, compressed.readableBytes)
            let chunk = compressed.getSlice(at: offset, length: chunkSize)!
            continuation.yield(chunk)
            offset = end
        }
        continuation.finish()
    }
    var r = try await stream.decodeBzip2().collect(upTo: 1024)
    #expect(r.readableBytes == 12)
    let str = r.readString(length: r.readableBytes)!
    #expect(str == "Hello World\n")
}

```
