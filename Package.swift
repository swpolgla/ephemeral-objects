// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ephemeral-objects",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.5.2"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.6.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ephemeral-objects",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Leaf", package: "leaf")
            ],
            exclude: ["mgmt-ui"],
        ),
        .testTarget(
            name: "ephemeral-objectsTests",
            dependencies: [
                "ephemeral-objects",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ],
    swiftLanguageModes: [.v6],
)
