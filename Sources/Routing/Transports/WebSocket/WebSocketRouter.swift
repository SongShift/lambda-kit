//
//  WebSocketRouter.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

//  All WebSocket-specific routing knowledge lives in this file:
//
//    1. The convention for translating a WebSocket route key into a routing key
//       (`WebSocketRequest.route(_:)`), used by both registration and dispatch.
//    2. Static factories for the well-known framework route keys
//       (`WebSocketRequest.connect()`, `.disconnect()`).
//    3. `WebSocketRequest`'s `Routable.routingKey` conformance, delegating to
//       (1) so that registration and dispatch can never drift apart.
//    4. The `WebSocketRouterBuilder` / `WebSocketRouter` typealiases and
//       constrained `RouterBuilder`/`RouteGroup` extensions providing call-site
//       sugar (`builder.connect { ... }`, `builder.on("subscribe") { ... }`, etc.).
//
//  WebSocket routing uses a `DictionaryRouter` engine because API Gateway
//  WebSocket routes are flat string identifiers (`$connect`, `subscribe`, etc.).
//  There's no hierarchy, no path parameters, and no benefit from a trie. Forcing
//  WebSocket through `TrieRouter` would be using the wrong data structure for
//  the problem.
//

import Logging
import RoutingKit

// MARK: - WebSocketRequest: routing key convention

public extension WebSocketRequest {
    /// Build a routing key for a WebSocket message from its route key.
    ///
    /// This is the **single source of truth** for how WebSocket events map to
    /// routing keys. Both registration (via `WebSocketRequest.connect()` and
    /// friends) and dispatch (via `WebSocketRequest.routingKey`) call through
    /// here. If you change this function, both sides update automatically.
    /// They cannot drift apart.
    static func route(_ routeKey: String) -> [String] {
        [routeKey]
    }

    /// Build a routing key for the framework `$connect` route.
    static func connect() -> [String] {
        self.route("$connect")
    }

    /// Build a routing key for the framework `$disconnect` route.
    static func disconnect() -> [String] {
        self.route("$disconnect")
    }

    /// The routing key used to dispatch this message. Symmetric with the static
    /// factories above, both go through `route(_:)`.
    var routingKey: [String] {
        Self.route(self.event.context.routeKey)
    }
}

// MARK: - WebSocket typealiases

/// A `RouterBuilder` specialized for AWS Lambda WebSocket messages, backed by a
/// `DictionaryRouter` engine.
public typealias WebSocketRouterBuilder = RouterBuilder<
    WebSocketRequest,
    DictionaryRouterBuilder<RouteHandler<WebSocketRequest>>
>

/// An immutable `Router` specialized for AWS Lambda WebSocket messages, produced
/// by calling `build()` on a `WebSocketRouterBuilder`.
public typealias WebSocketRouter = Router<WebSocketRequest>

// MARK: - WebSocket convenience init

public extension RouterBuilder where R == WebSocketRequest,
    Engine == DictionaryRouterBuilder<RouteHandler<WebSocketRequest>> {
    /// Construct a WebSocket router builder backed by a default `DictionaryRouter` engine.
    convenience init() {
        self.init(engine: DictionaryRouterBuilder())
    }
}

// MARK: - RouterBuilder WebSocket sugar

public extension RouterBuilder where R == WebSocketRequest,
    Engine == DictionaryRouterBuilder<RouteHandler<WebSocketRequest>> {
    /// Register a handler for the framework `$connect` route.
    func connect(
        use handler: @Sendable @escaping (WebSocketRequest, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.connect(), use: handler)
    }

    /// Register a handler for the framework `$disconnect` route.
    func disconnect(
        use handler: @Sendable @escaping (WebSocketRequest, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.disconnect(), use: handler)
    }

    /// Register a handler for a custom WebSocket route key.
    func on(
        _ routeKey: String,
        use handler: @Sendable @escaping (WebSocketRequest, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.route(routeKey), use: handler)
    }
}

// MARK: - RouteGroup WebSocket sugar

public extension RouteGroup where R == WebSocketRequest,
    Engine == DictionaryRouterBuilder<RouteHandler<WebSocketRequest>> {
    /// Register a handler for the framework `$connect` route, running through
    /// this group's middleware first.
    func connect(
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.connect(), use: handler)
    }

    /// Register a handler for the framework `$disconnect` route, running
    /// through this group's middleware first.
    func disconnect(
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.disconnect(), use: handler)
    }

    /// Register a handler for a custom WebSocket route key, running through
    /// this group's middleware first.
    func on(
        _ routeKey: String,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.route(routeKey), use: handler)
    }

    /// Register a handler for a custom WebSocket route key with a JSON-decoded
    /// body, running through this group's middleware first.
    func on<Body: Decodable & Sendable>(
        _ routeKey: String,
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) {
        self.on(WebSocketRequest.route(routeKey), body: body, use: handler)
    }
}
