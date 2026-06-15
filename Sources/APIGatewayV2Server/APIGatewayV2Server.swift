//
//  APIGatewayV2Server.swift
//  LambdaKit
//

import AsyncHTTPClient
import AWSLambdaEvents
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import Logging
import NIOFoundationCompat
import NIOSSL

/// Local development HTTP server that proxies requests to a Lambda local server.
/// Accepts real HTTP requests, translates them to `APIGatewayV2Request` JSON,
/// and POSTs to the Lambda's `/invoke` endpoint.
public struct APIGatewayV2Server: Sendable {
    private let requestTransformer: (any RequestTransformer)?
    private let httpHost: String
    private let httpPort: Int
    private let lambdaHost: String
    private let lambdaPort: Int
    private let logger: Logger
    private let tlsConfiguration: TLSConfiguration?

    public init(
        httpHost: String = "127.0.0.1",
        httpPort: Int,
        lambdaHost: String = "127.0.0.1",
        lambdaPort: Int,
        tlsConfiguration: TLSConfiguration? = nil,
        logger: Logger = Logger(label: "APIGatewayV2Server"),
        requestTransformer: (any RequestTransformer)? = nil
    ) {
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.lambdaHost = lambdaHost
        self.lambdaPort = lambdaPort
        self.tlsConfiguration = tlsConfiguration
        self.logger = logger
        self.requestTransformer = requestTransformer
    }

    public init(
        httpHost: String = "127.0.0.1",
        httpPort: Int,
        lambdaHost: String = "127.0.0.1",
        lambdaPort: Int,
        tlsCertificatePath: String,
        tlsPrivateKeyPath: String,
        logger: Logger = Logger(label: "APIGatewayV2Server"),
        requestTransformer: (any RequestTransformer)? = nil
    ) throws {
        let certs = try NIOSSLCertificate.fromPEMFile(tlsCertificatePath)
        let privateKey = try NIOSSLPrivateKey(file: tlsPrivateKeyPath, format: .pem)
        let tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        self.init(
            httpHost: httpHost,
            httpPort: httpPort,
            lambdaHost: lambdaHost,
            lambdaPort: lambdaPort,
            tlsConfiguration: tlsConfig,
            logger: logger,
            requestTransformer: requestTransformer
        )
    }

    public func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let router = Router()

        for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete, .head, .options] {
            router.on("**", method: method) { request, context -> Response in
                try await self.handleRequest(request, context: context, httpClient: httpClient)
            }
        }

        // Suppress Hummingbird's redundant "Server started" log
        var hbLogger = Logger(label: "HummingbirdCore")
        hbLogger.logLevel = .warning

        let serverBuilder: HTTPServerBuilder
        if let tlsConfiguration {
            serverBuilder = try .tls(tlsConfiguration: tlsConfiguration)
        } else {
            serverBuilder = .http1()
        }

        let app = Application(
            router: router,
            server: serverBuilder,
            configuration: .init(address: .hostname(httpHost, port: httpPort)),
            logger: hbLogger
        )

        let scheme = tlsConfiguration != nil ? "https" : "http"
        self.logger.info("Listening on \(scheme)://\(self.httpHost):\(self.httpPort) → \(self.lambdaHost):\(self.lambdaPort)/invoke")
        try await app.runService()
    }

    private func handleRequest(
        _ request: Request,
        context: some RequestContext,
        httpClient: HTTPClient
    ) async throws -> Response {
        let body = try await request.body.collect(upTo: 10 * 1024 * 1024)
        var builder = MutableAPIGatewayV2Request(from: request, body: body, host: httpHost)

        if let requestTransformer {
            await requestTransformer.transform(&builder)
        }

        let requestJSON = try JSONEncoder().encode(builder)

        var httpRequest = HTTPClientRequest(url: "http://\(lambdaHost):\(lambdaPort)/invoke")
        httpRequest.method = .POST
        httpRequest.headers.add(name: "Content-Type", value: "application/json")
        httpRequest.body = .bytes(requestJSON)

        let response = try await httpClient.execute(httpRequest, timeout: .seconds(30))
        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)

        let apiResponse = try JSONDecoder().decode(APIGatewayV2Response.self, from: Data(buffer: responseBody))
        return apiResponse.toHummingbirdResponse()
    }
}
