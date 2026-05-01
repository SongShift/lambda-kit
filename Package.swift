// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "LambdaKit",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Routing",
            targets: ["Routing"]
        ),
        .library(
                name: "DynamoQueries",
                targets: ["DynamoQueries"]
            ),
        .library(
            name: "DynamoQueriesSoto",
            targets: ["DynamoQueriesSoto"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/routing-kit.git", exact: "5.0.0-beta.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events", from: "1.2.3"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime", revision: "2.6.2"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Routing",
            dependencies: [
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .target(
            name: "DynamoQueries",
            dependencies: ["DynamoQueriesMacros"]
        ),
        .target(
            name: "DynamoQueriesSoto",
            dependencies: [
                "DynamoQueries",
                .product(name: "SotoDynamoDB", package: "soto"),
            ]
        ),
        .macro(
            name: "DynamoQueriesMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DynamoQueriesTests",
            dependencies: [
                "DynamoQueries",
                "DynamoQueriesSoto",
                .product(name: "SotoDynamoDB", package: "soto"),
            ]
        ),
        .executableTarget(
            name: "RoutingDemo",
            dependencies: [
                "Routing",
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
            ],
            path: "Examples/RoutingDemo/Sources"
        ),
        .executableTarget(
            name: "DynamoQueriesDemo",
            dependencies: ["DynamoQueries"],
            path: "Examples/DynamoQueriesDemo/Sources"
        ),
        .executableTarget(
            name: "TrailLogDemo",
            dependencies: [
                "Routing",
                "DynamoQueries",
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
            ],
            path: "Examples/TrailLog/Sources"
        ),
    ]
)
