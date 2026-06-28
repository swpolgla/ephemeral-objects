// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ephemeral-objects",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ephemeral-objects"
        ),
        .testTarget(
            name: "ephemeral-objectsTests",
            dependencies: ["ephemeral-objects"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
