// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-io",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .tvOS(.v27),
        .watchOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(
            name: "IO",
            targets: ["IO"]
        ),
        .library(
            name: "IO Events",
            targets: ["IO Events"]
        ),
        .library(
            name: "IO Completions",
            targets: ["IO Completions"]
        ),
        .library(
            name: "IO Test Support",
            targets: ["IO Test Support"]
        ),
        .library(
            name: "IO Completions Test Support",
            targets: ["IO Completions Test Support"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-compositions/swift-kernel.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-compositions/swift-async.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-compositions/swift-executors.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-compositions/swift-threads.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-compositions/swift-synchronizers.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-io.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-buffer.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-hash.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-heap.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-dictionary.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-hash-table.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-buffer-linear.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-storage.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-memory-heap.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-memory-allocation.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-memory.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-span.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-either.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-molecules/swift-witness.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-compositions/swift-witnesses.git",
            branch: "main"
        ),
    ],
    targets: [

        .target(
            name: "IO Events",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "IO", package: "swift-io"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Async", package: "swift-async"),
                .product(name: "Hash", package: "swift-hash"),
                .product(name: "Heap Primitive", package: "swift-heap"),
                .product(name: "Buffer", package: "swift-buffer"),
                .product(name: "Memory", package: "swift-memory"),
                .product(name: "Dictionary", package: "swift-dictionary"),
                .product(name: "Witness", package: "swift-witness"),
                .product(name: "Witnesses", package: "swift-witnesses"),
                .product(name: "Either", package: "swift-either"),
            ],
        ),

        .target(
            name: "IO Completions",
            dependencies: [
                .product(
                    name: "Kernel",
                    package: "swift-kernel"
                ),
                .product(
                    name: "Kernel Completion",
                    package: "swift-kernel"
                ),
                .product(
                    name: "IO",
                    package: "swift-io"
                ),
                .product(
                    name: "Executors",
                    package: "swift-executors"
                ),
                .product(
                    name: "Async",
                    package: "swift-async"
                ),
                .product(
                    name: "Memory",
                    package: "swift-memory"
                ),
                .product(
                    name: "Dictionary",
                    package: "swift-dictionary"
                ),
                .product(
                    name: "Hash Indexed Primitive",
                    package: "swift-hash-table"
                ),
                .product(
                    name: "Hash Tagged",
                    package: "swift-hash"
                ),
                .product(
                    name: "Buffer Primitive",
                    package: "swift-buffer"
                ),
                .product(
                    name: "Buffer Linear Primitive",
                    package: "swift-buffer-linear"
                ),
                .product(
                    name: "Buffer Linear",
                    package: "swift-buffer-linear"
                ),
                .product(name: "Storage Primitive", package: "swift-storage"),
                .product(
                    name: "Storage Contiguous",
                    package: "swift-storage"
                ),
                .product(name: "Memory Heap", package: "swift-memory-heap"),
                .product(
                    name: "Memory Allocator Primitive",
                    package: "swift-memory-allocation"
                ),
                .product(name: "Synchronizer Blocking", package: "swift-synchronizers"),
            ]
        ),

        .target(
            name: "IO",
            dependencies: [
                "IO Events",
                "IO Completions",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "IO", package: "swift-io"),
                .product(name: "Either", package: "swift-either"),
            ]
        ),

        .target(
            name: "IO Test Support",
            dependencies: [
                .product(name: "Span Raw", package: "swift-span"),
                "IO",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Kernel Test Support", package: "swift-kernel"),
                .product(name: "IO", package: "swift-io"),
                .product(name: "Thread Actor", package: "swift-threads"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Buffer", package: "swift-buffer"),
                .product(name: "Memory", package: "swift-memory"),
            ],
            path: "Tests/Support"
        ),

        .target(
            name: "IO Completions Test Support",
            dependencies: [
                "IO Completions",
                "IO Events",
                "IO Test Support",
                .product(name: "Synchronizer Blocking", package: "swift-synchronizers"),
            ],
            path: "Tests/Completions Support"
        ),

        .testTarget(
            name: "IO Basic Tests",
            dependencies: [
                "IO Test Support"
            ],
            path: "Tests/IO Blocking Tests"
        ),
        .testTarget(
            name: "IO Completions Tests",
            dependencies: [
                "IO Completions",
                "IO Completions Test Support",
            ]
        ),
        .testTarget(
            name: "IO Tests",
            dependencies: [
                "IO",
                "IO Test Support",
            ]
        ),
        .testTarget(
            name: "IO Events Tests",
            dependencies: [
                "IO Events",
                "IO Test Support",
            ]
        )
    ]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]

    let package: [SwiftSetting] = []

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}
