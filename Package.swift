// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftParallelBzip2",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftParallelBzip2",
            targets: ["SwiftParallelBzip2"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftParallelBzip2",
            dependencies: [
                .target(name: "Lbzip2"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "NIOCore", package: "swift-nio")
            ]
        ),
        .target(
            name: "Lbzip2"
        ),
        .executableTarget(
            name: "Run",
            dependencies: [
                .target(name: "SwiftParallelBzip2"),
                .product(name: "_NIOFileSystem", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "SwiftParallelBzip2Tests",
            dependencies: ["SwiftParallelBzip2"]
        ),
    ]
)
