// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LambdaKit",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Routing",
            targets: ["Routing"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/routing-kit.git", exact: "5.0.0-beta.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events", from: "1.2.3"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Routing",
            dependencies: [
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        )
    ]
)
