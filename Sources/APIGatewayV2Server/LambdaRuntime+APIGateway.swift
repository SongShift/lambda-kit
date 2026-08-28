//
//  LambdaRuntime+APIGateway.swift
//  LambdaKit
//

import AWSLambdaRuntime
import Foundation
import Logging

/// Configuration for one local HTTP gateway server: the port to listen on, and
/// an optional transformer to fill in what the real gateway would have put on
/// the event.
public struct LocalGateway: Sendable {
    /// Interface the HTTP server binds to.
    public let httpHost: String

    /// Port the HTTP server listens on.
    public let httpPort: Int

    /// PEM certificate chain and private key. Set both to serve HTTPS.
    public let tlsCertificatePath: String?
    public let tlsPrivateKeyPath: String?

    /// Runs on every request after it's been turned into an
    /// `APIGatewayV2Request`. This is where you fake what the real gateway
    /// would have added, like an API ID or auth headers.
    public let requestTransformer: (any RequestTransformer)?

    public init(
        httpHost: String = "127.0.0.1",
        httpPort: Int,
        tlsCertificatePath: String? = nil,
        tlsPrivateKeyPath: String? = nil,
        requestTransformer: (any RequestTransformer)? = nil
    ) {
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.requestTransformer = requestTransformer
    }
}

public extension LambdaRuntime {
    /// Runs the Lambda runtime alongside an HTTP gateway server for local development.
    ///
    /// - Lambda runtime listens on `lambdaPort` (default 7000) for `/invoke` requests
    /// - HTTP gateway listens on `httpPort` (default 3000) for real HTTP requests
    ///
    /// The gateway translates HTTP requests to `APIGatewayV2Request` JSON and
    /// forwards them to the Lambda's `/invoke` endpoint.
    ///
    /// Example:
    /// ```swift
    /// #if DEBUG
    /// try await runtime.runWithAPIGateway(requestTransformer: AuthTransformer())
    /// #else
    /// try await runtime.run()
    /// #endif
    /// ```
    func runWithAPIGateway(
        logger: Logger = Logger(label: "APIGatewayV2Server"),
        requestTransformer: (any RequestTransformer)? = nil
    ) async throws {
        let env = ProcessInfo.processInfo.environment
        let gateway = LocalGateway(
            httpHost: env["LOCAL_HTTP_HOST"] ?? "127.0.0.1",
            httpPort: env["LOCAL_HTTP_PORT"].flatMap(Int.init) ?? 3000,
            tlsCertificatePath: env["LOCAL_TLS_CERT_FILE"],
            tlsPrivateKeyPath: env["LOCAL_TLS_KEY_FILE"],
            requestTransformer: requestTransformer
        )
        try await self.runWithAPIGateways([gateway], logger: logger)
    }

    /// Like `runWithAPIGateway`, but starts one HTTP server per `LocalGateway`.
    ///
    /// Reach for this when the same Lambda serves more than one API Gateway in
    /// AWS and you want the same setup locally: each gateway on its own port,
    /// all forwarding to the one runtime.
    ///
    /// The runtime's `/invoke` address still comes from `LOCAL_LAMBDA_HOST` /
    /// `LOCAL_LAMBDA_PORT`, since it has to match what the runtime itself
    /// listens on. Everything about the HTTP servers lives on the
    /// `LocalGateway` values.
    ///
    /// Example:
    /// ```swift
    /// #if DEBUG
    /// try await runtime.runWithAPIGateways([
    ///     .init(httpPort: 3001, requestTransformer: SetAPIId(tokensApiId)),
    ///     .init(httpPort: 3002, requestTransformer: SetAPIId(cloudApiId)),
    /// ])
    /// #else
    /// try await runtime.run()
    /// #endif
    /// ```
    func runWithAPIGateways(
        _ gateways: [LocalGateway],
        logger: Logger = Logger(label: "APIGatewayV2Server")
    ) async throws {
        precondition(!gateways.isEmpty, "runWithAPIGateways requires at least one gateway")
        precondition(
            Set(gateways.map(\.httpPort)).count == gateways.count,
            "Each local gateway needs a distinct httpPort"
        )

        let env = ProcessInfo.processInfo.environment
        let lambdaHost = env["LOCAL_LAMBDA_HOST"] ?? "127.0.0.1"
        let lambdaPort = env["LOCAL_LAMBDA_PORT"].flatMap(Int.init) ?? 7000

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.run()
            }

            for gateway in gateways {
                group.addTask {
                    try await Task.sleep(for: .milliseconds(200))
                    let server = APIGatewayV2Server(
                        httpHost: gateway.httpHost,
                        httpPort: gateway.httpPort,
                        lambdaHost: lambdaHost,
                        lambdaPort: lambdaPort,
                        tlsCertificatePath: gateway.tlsCertificatePath,
                        tlsPrivateKeyPath: gateway.tlsPrivateKeyPath,
                        logger: logger,
                        requestTransformer: gateway.requestTransformer
                    )
                    try await server.run()
                }
            }

            try await group.waitForAll()
        }
    }
}
