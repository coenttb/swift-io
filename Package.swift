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
    ],
    dependencies: [
        .package(path: "../../swift-standards/swift-time-standard"),
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
        .testTarget(
            name: "IO Tests",
            dependencies: ["IO"]
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
