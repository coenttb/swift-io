// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-io",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "IO", targets: ["IO"]),
        .library(name: "IO Primitives", targets: ["IO Primitives"]),
        .library(name: "IO Blocking", targets: ["IO Blocking"]),
        .library(name: "IO Blocking Threads", targets: ["IO Blocking Threads"]),
        .library(name: "IO Events Primitives", targets: ["IO Events Primitives"]),
        .library(name: "IO Events Driver", targets: ["IO Events Driver"]),
        .library(name: "IO Events Kqueue", targets: ["IO Events Kqueue"]),
        .library(name: "IO Events", targets: ["IO Events"]),
        .library(name: "IO Completions Primitives", targets: ["IO Completions Primitives"]),
        .library(name: "IO Completions Driver", targets: ["IO Completions Driver"]),
        .library(name: "IO Completions", targets: ["IO Completions"]),
    ],
    traits: [
        .trait(name: "Codable", description: "Enable Codable conformances for Handle.ID and other types"),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-standards/swift-time-standard.git", from: "0.2.0"),
        .package(url: "https://github.com/swift-standards/swift-standards", from: "0.24.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(path: "../swift-kernel"),
        .package(path: "../swift-memory"),
//        .package(url: "https://github.com/coenttb/swift-kernel.git", from: "0.2.0"),
//        .package(url: "https://github.com/coenttb/swift-memory.git", from: "0.1.0"),
        .package(path: "../swift-buffer"),
//        .package(url: "https://github.com/coenttb/swift-buffer.git", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "IO Primitives",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Buffer", package: "swift-buffer"),
                .product(name: "Binary", package: "swift-standards"),
            ]
        ),
        .target(
            name: "IO Blocking",
            dependencies: [
                "IO Primitives",
                .product(name: "Clocks", package: "swift-time-standard"),
            ]
        ),
        .target(
            name: "IO Blocking Threads",
            dependencies: ["IO Blocking"],
            swiftSettings: [
                .define("IO_TESTING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "IO",
            dependencies: [
                "IO Blocking",
                "IO Blocking Threads",
                .product(name: "Memory", package: "swift-memory"),
            ]
        ),
        .target(
            name: "IO Events Primitives",
            dependencies: ["IO Primitives"]
        ),
        .target(
            name: "IO Events Driver",
            dependencies: ["IO Events Primitives"]
        ),
        .target(
            name: "IO Events Kqueue",
            dependencies: ["IO Events Driver"]
        ),
        .target(
            name: "IO Events Epoll",
            dependencies: [
                "IO Events Driver",
                .product(name: "Kernel", package: "swift-kernel"),
            ]
        ),
        .target(
            name: "IO Events",
            dependencies: [
                "IO Events Driver",
                .target(name: "IO Events Kqueue", condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS])),
                .target(name: "IO Events Epoll", condition: .when(platforms: [.linux])),
                .product(name: "Binary", package: "swift-standards"),
            ]
        ),
        .target(
            name: "IO Completions Primitives",
            dependencies: [
                "IO Primitives",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Buffer", package: "swift-buffer"),
            ]
        ),
        .target(
            name: "IO Completions Driver",
            dependencies: ["IO Completions Primitives"]
        ),
        .target(
            name: "IO Completions IOCP",
            dependencies: ["IO Completions Driver"]
        ),
        .target(
            name: "IO Completions IOUring",
            dependencies: [
                "IO Completions Driver",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Memory", package: "swift-memory"),
            ]
        ),
        .target(
            name: "IO Completions",
            dependencies: [
                "IO Completions Driver",
                "IO Events",
                .product(name: "Buffer", package: "swift-buffer"),
                .target(name: "IO Completions IOCP", condition: .when(platforms: [.windows])),
                .target(name: "IO Completions IOUring", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "IO Primitives Tests",
            dependencies: [
                "IO Primitives",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Blocking Tests",
            dependencies: [
                "IO Blocking",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .target(
            name: "IO Test Support",
            dependencies: [
                "IO Blocking Threads",
                .product(name: "Kernel Test Support", package: "swift-kernel"),
            ],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "IO Blocking Threads Tests",
            dependencies: [
                "IO Blocking Threads",
                "IO Test Support",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Tests",
            dependencies: [
                "IO",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Events Primitives Tests",
            dependencies: [
                "IO Events Primitives",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Events Tests",
            dependencies: [
                "IO Events",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Completions Tests",
            dependencies: [
                "IO Completions",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Benchmarks",
            dependencies: [
                "IO",
                "IO Test Support",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ],
            path: "Tests/IO Benchmarks"
        ),
        .testTarget(
            name: "IO Events Benchmarks",
            dependencies: [
                "IO Events",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ],
            path: "Tests/IO Events Benchmarks"
        ),
    ]
)

for target in package.targets where ![.system, .binary, .plugin].contains(target.type) {
    let settings: [SwiftSetting] = [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .define("CODABLE", .when(traits: ["Codable"])),
    ]
    target.swiftSettings = (target.swiftSettings ?? []) + settings
}
