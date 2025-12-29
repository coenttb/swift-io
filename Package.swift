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
        .library(name: "IO NonBlocking Primitives", targets: ["IO NonBlocking Primitives"]),
        .library(name: "IO NonBlocking Driver", targets: ["IO NonBlocking Driver"]),
        .library(name: "IO NonBlocking Kqueue", targets: ["IO NonBlocking Kqueue"]),
        .library(name: "IO NonBlocking", targets: ["IO NonBlocking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-standards/swift-time-standard.git", from: "0.2.0"),
        .package(url: "https://github.com/swift-standards/swift-standards", from: "0.19.4"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
    ],
    targets: [
        .target(
            name: "IO Primitives"
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
            dependencies: ["IO Blocking"]
        ),
        .target(
            name: "IO",
            dependencies: ["IO Blocking", "IO Blocking Threads"]
        ),
        .target(
            name: "IO NonBlocking Primitives",
            dependencies: ["IO Primitives"]
        ),
        .target(
            name: "IO NonBlocking Driver",
            dependencies: ["IO NonBlocking Primitives"]
        ),
        .target(
            name: "IO NonBlocking Kqueue",
            dependencies: ["IO NonBlocking Driver"]
        ),
        .target(
            name: "IO NonBlocking",
            dependencies: [
                "IO NonBlocking Driver",
                "IO NonBlocking Kqueue",
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
        .testTarget(
            name: "IO Blocking Threads Tests",
            dependencies: [
                "IO Blocking Threads",
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
            name: "IO NonBlocking Primitives Tests",
            dependencies: [
                "IO NonBlocking Primitives",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO NonBlocking Tests",
            dependencies: [
                "IO NonBlocking",
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ]
        ),
        .testTarget(
            name: "IO Benchmarks",
            dependencies: [
                "IO",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "StandardsTestSupport", package: "swift-standards"),
            ],
            path: "Tests/IO Benchmarks"
        ),
    ]
)

for target in package.targets where ![.system, .binary, .plugin].contains(target.type) {
    let existing = target.swiftSettings ?? []
    target.swiftSettings =
        existing + [
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("MemberImportVisibility"),
        ]
}
