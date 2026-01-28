// swift-tools-version: 5.9
// This Package.swift is for local build verification only.
// The actual project uses the Xcode project with SPM dependencies.

import PackageDescription

let package = Package(
    name: "EasyProxy",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "EasyProxy",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            path: "EasyProxy"
        ),
    ]
)
