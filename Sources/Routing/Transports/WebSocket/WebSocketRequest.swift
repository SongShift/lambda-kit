//
//  WebSocketRequest.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import AWSLambdaEvents
import Foundation

/// A WebSocket message, modeled as a thin `@dynamicMemberLookup` wrapper around
/// an AWS Lambda `APIGatewayWebSocketRequest` event.
///
/// `WebSocketRequest` mirrors `HTTPRequest`: it exposes a small set of typed
/// conveniences as explicit stored properties (`body`, `pathParameters`,
/// `queryParameters`, `headers`) and forwards every other member access through
/// to the underlying event. Handlers therefore see the full surface of the AWS
/// event — including `connectionId` and `routeKey` — without us having to
/// surface each field manually.
///
/// ```swift
/// router.on("subscribe", body: SubscribePayload.self) { req, payload, logger in
///     let connectionId = req.context.connectionId  // forwarded to event.context
///     let routeKey = req.context.routeKey          // forwarded to event.context
///     // payload is the JSON-decoded body
/// }
/// ```
///
/// The `Routable` conformance — including `routingKey` — and the static
/// factories for building registration keys live in `WebSocketRouter.swift` so
/// that all WebSocket-specific routing knowledge is colocated.
@dynamicMemberLookup
public struct WebSocketRequest: Routable {
    /// The underlying AWS Lambda event. Reach for this when you want to be
    /// explicit, or when overload resolution would otherwise be ambiguous.
    public let event: APIGatewayWebSocketRequest

    /// Path parameters matched by the router during trie lookup. WebSocket
    /// routes rarely use path parameters, but the slot exists for parity with
    /// HTTP routing and so the `Routable` protocol can be satisfied uniformly.
    public var pathParameters: PathParameters

    /// Query string parameters, parsed into the typed `QueryParameters` API.
    /// API Gateway only populates these on the `$connect` upgrade request, so
    /// most non-`$connect` handlers won't have anything here.
    public let queryParameters: QueryParameters

    /// HTTP headers from the upgrade request, exposed via the case-insensitive
    /// `Headers` API. API Gateway only populates these on the `$connect`
    /// upgrade request, so non-`$connect` handlers won't see anything here.
    public let headers: Headers

    /// Decoded message body. Base64-encoded payloads are decoded once at
    /// construction time so handlers can read `req.body` without re-decoding.
    public let body: Data

    public init(event: APIGatewayWebSocketRequest) {
        self.event = event
        self.pathParameters = .init()
        self.queryParameters = QueryParameters(values: event.queryStringParameters ?? [:])
        self.headers = Headers(values: event.headers ?? [:])
        if event.isBase64Encoded ?? false, let encoded = event.body {
            self.body = Data(base64Encoded: encoded) ?? .init()
        } else {
            self.body = event.body.flatMap { $0.data(using: .utf8) } ?? .init()
        }
    }

    /// Forward member access to the underlying AWS event. Explicit stored
    /// properties on `WebSocketRequest` (such as `body`, `pathParameters`,
    /// `queryParameters`) take precedence over this subscript.
    public subscript<T>(dynamicMember keyPath: KeyPath<APIGatewayWebSocketRequest, T>) -> T {
        self.event[keyPath: keyPath]
    }
}
