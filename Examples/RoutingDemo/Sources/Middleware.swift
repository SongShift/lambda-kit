//
//  Middleware.swift
//
//  The two middlewares used by the demo: a passthrough request logger and a
//  bearer-token auth middleware that resolves to a `HikerID`.
//

import Foundation
import Logging
import Routing

/// Logs every request that reaches the chain and the status of the response
/// produced. Doesn't transform the input — passes the original `HTTPRequest`
/// through unchanged.
struct LoggingMiddleware: MiddlewareProtocol {
    func handle(
        _ input: HTTPRequest,
        next: @Sendable (HTTPRequest, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        let method = input.event.context.http.method.rawValue
        let path = input.event.pathParameters["proxy"] ?? input.event.rawPath
        logger.info("→ \(method) /\(path)")
        let response = try await next(input, logger)
        logger.info("← \(response.statusCode)")
        return response
    }
}

/// Stand-in for a real auth check. Always succeeds and produces a fixed
/// `HikerID` — a production middleware would verify a JWT (or similar)
/// against an identity provider and short-circuit with `401` on failure.
struct AuthMiddleware: Middleware {
    typealias Input = HTTPRequest
    typealias Value = HikerID

    struct HikerID: Sendable, Codable {
        let value: String
    }

    func process(
        _ input: HTTPRequest,
        logger _: Logger
    ) async throws -> MiddlewareAction<HikerID> {
        .next(HikerID(value: "demo-hiker"))
    }
}
