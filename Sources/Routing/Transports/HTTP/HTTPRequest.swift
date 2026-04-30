//
//  HTTPRequest.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import AWSLambdaEvents
import Foundation

/// An HTTP request, modeled as a thin `@dynamicMemberLookup` wrapper around an
/// AWS Lambda `APIGatewayV2Request` event.
///
/// `HTTPRequest` exposes a small set of typed conveniences as explicit stored
/// properties — `body`, `pathParameters`, `queryParameters`, `headers` — and
/// forwards every other member access through to the underlying event. Handlers
/// therefore see the full surface of the AWS event without us having to surface
/// each field manually:
///
/// ```swift
/// router.get("/something") { req, logger in
///     let userAgent = req.headers["user-agent"]              // case-insensitive lookup
///     let stage = req.context.stage                          // forwarded to event.context
///     let linkId = try req.pathParameters.require("linkId")  // typed convenience
///     let cursor = req.queryParameters.get("cursor")         // typed convenience
///     let body = try JSONDecoder().decode(Foo.self, from: req.body)
/// }
/// ```
///
/// The `Routable` conformance — including `routingKey` — and the static
/// factories for building registration keys (`HTTPRequest.get(_:)`,
/// `HTTPRequest.post(_:)`, etc.) live in `HTTPRouter.swift` so that all
/// HTTP-specific routing knowledge is colocated.
@dynamicMemberLookup
public struct HTTPRequest: Routable {
    /// The underlying AWS Lambda event. Reach for this when you want to be
    /// explicit, or when overload resolution would otherwise be ambiguous.
    public let event: APIGatewayV2Request

    /// Path parameters matched by the router during trie lookup. Mutable because
    /// the router writes into this slot after a successful match.
    public var pathParameters: PathParameters

    /// Query string parameters, parsed into the typed `QueryParameters` API.
    public let queryParameters: QueryParameters

    /// HTTP headers exposed via the case-insensitive `Headers` API. This shadows
    /// the underlying `event.headers` `[String: String]` so callers don't have
    /// to worry about whether the upstream sent `"Host"` vs `"host"`.
    public let headers: Headers

    /// Decoded request body. Base64-encoded payloads are decoded once at
    /// construction time so handlers can read `req.body` without re-decoding.
    public let body: Data

    public init(event: APIGatewayV2Request) {
        self.event = event
        self.pathParameters = .init()
        self.queryParameters = QueryParameters(values: event.queryStringParameters)
        self.headers = Headers(values: event.headers)
        if event.isBase64Encoded, let encoded = event.body {
            self.body = Data(base64Encoded: encoded) ?? .init()
        } else {
            self.body = event.body.flatMap { $0.data(using: .utf8) } ?? .init()
        }
    }

    /// Forward member access to the underlying AWS event. Explicit stored
    /// properties on `HTTPRequest` (such as `body`, `pathParameters`,
    /// `queryParameters`) take precedence over this subscript.
    public subscript<T>(dynamicMember keyPath: KeyPath<APIGatewayV2Request, T>) -> T {
        self.event[keyPath: keyPath]
    }
}
