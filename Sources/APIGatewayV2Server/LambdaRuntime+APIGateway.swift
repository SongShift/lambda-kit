//
//  LambdaRuntime+APIGateway.swift
//  LambdaKit
//

import AWSLambdaRuntime
import Foundation
import Logging

public extension LambdaRuntime {
    /// Runs the Lambda runtime alongside an HTTP gateway server for local development.
    ///
    /// - Lambda runtime listens on `lambdaPort` (default 7000) for `/invoke` requests
    /// - HTTP gateway listens on `httpPort` (default 7001) for real HTTP requests
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
        let lambdaHost = env["LOCAL_LAMBDA_HOST"] ?? "127.0.0.1"
        let lambdaPort = env["LOCAL_LAMBDA_PORT"].flatMap(Int.init) ?? 7000
        let httpHost = env["LOCAL_HTTP_HOST"] ?? "127.0.0.1"
        let httpPort = env["LOCAL_HTTP_PORT"].flatMap(Int.init) ?? 3000
        let tlsCertPath = env["LOCAL_TLS_CERT_FILE"]
        let tlsKeyPath = env["LOCAL_TLS_KEY_FILE"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.run()
            }

            group.addTask {
                try await Task.sleep(for: .milliseconds(200))

                let server: APIGatewayV2Server
                if let tlsCertPath, let tlsKeyPath {
                    server = try APIGatewayV2Server(
                        httpHost: httpHost,
                        httpPort: httpPort,
                        lambdaHost: lambdaHost,
                        lambdaPort: lambdaPort,
                        tlsCertificatePath: tlsCertPath,
                        tlsPrivateKeyPath: tlsKeyPath,
                        logger: logger,
                        requestTransformer: requestTransformer
                    )
                } else {
                    server = APIGatewayV2Server(
                        httpHost: httpHost,
                        httpPort: httpPort,
                        lambdaHost: lambdaHost,
                        lambdaPort: lambdaPort,
                        logger: logger,
                        requestTransformer: requestTransformer
                    )
                }

                try await server.run()
            }

            try await group.waitForAll()
        }
    }
}
