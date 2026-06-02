// swift-tools-version: 6.2

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
        .library(
            name: "DynamoQueriesTestSupport",
            targets: ["DynamoQueriesTestSupport"]
        ),
        .library(
            name: "DynamoQueriesSnapshotTesting",
            targets: ["DynamoQueriesSnapshotTesting"]
        ),
        .library(name: "APIGatewayV2Server", targets: ["APIGatewayV2Server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/routing-kit.git", exact: "5.0.0-beta.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events", from: "1.2.3"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(
            url: "https://github.com/awslabs/swift-aws-lambda-runtime",
            revision: "2.6.2"
        ),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
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
            dependencies: [
                "DynamoQueriesMacros",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DynamoQueriesSoto",
            dependencies: [
                "DynamoQueries",
                .product(name: "SotoDynamoDB", package: "soto"),
            ]
        ),
        .target(
            name: "DynamoQueriesTestSupport",
            dependencies: ["DynamoQueries"]
        ),
        .target(
            name: "DynamoQueriesSnapshotTesting",
            dependencies: [
                "DynamoQueries",
                "DynamoQueriesTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
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
                "DynamoQueriesTestSupport",
                "DynamoQueriesSnapshotTesting",
                .product(name: "SotoDynamoDB", package: "soto"),
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
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
            dependencies: ["DynamoQueries", "DynamoQueriesTestSupport"],
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
        .target(
            name: "APIGatewayV2Server",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
    ]
)
