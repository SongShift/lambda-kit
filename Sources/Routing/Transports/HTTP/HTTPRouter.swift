//
//  HTTPRouter.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

//  All HTTP-specific routing knowledge lives in this file:
//
//    1. The convention for translating an HTTP method + path into a routing key
//       (`HTTPRequest.route(method:path:)`), used by both registration and
//       dispatch.
//    2. Static factories for building registration keys
//       (`HTTPRequest.get`, `.post`, `.delete`, `.put`, `.patch`).
//    3. `HTTPRequest`'s `Routable.routingKey` conformance, delegating to (1) so
//       that registration and dispatch can never drift apart.
//    4. The `HTTPRouterBuilder` / `HTTPRouter` typealiases and constrained
//       `RouterBuilder`/`RouteGroup` extensions providing call-site sugar
//       (`builder.get(path)`, etc.).
//
//  HTTP routing uses a `TrieRouter` engine because URL paths are hierarchical
//  and benefit from prefix sharing, parameter extraction, and wildcards. The
//  generic `Routing` core has zero knowledge of any of this; the WebSocket
//  counterpart in `WebSocketRouter.swift` mirrors this file but uses a
//  `DictionaryRouter` engine instead, since WebSocket route keys are flat.
//

import Logging
import RoutingKit

// MARK: - HTTPRequest: routing key convention

public extension HTTPRequest {
    /// Build a routing key for an HTTP request from its method and path.
    ///
    /// This is the **single source of truth** for how HTTP requests map to
    /// trie keys. Both registration (via `HTTPRequest.get(_:)` and friends) and
    /// dispatch (via `HTTPRequest.routingKey`) call through here. If you change
    /// this function, both sides update automatically — they cannot drift apart.
    static func route(method: String, path: String) -> [String] {
        [method] + path.split(separator: "/").map(String.init)
    }

    /// Build a routing key for a `GET` route.
    static func get(_ path: String) -> [String] {
        self.route(method: "GET", path: path)
    }

    /// Build a routing key for a `POST` route.
    static func post(_ path: String) -> [String] {
        self.route(method: "POST", path: path)
    }

    /// Build a routing key for a `DELETE` route.
    static func delete(_ path: String) -> [String] {
        self.route(method: "DELETE", path: path)
    }

    /// Build a routing key for a `PUT` route.
    static func put(_ path: String) -> [String] {
        self.route(method: "PUT", path: path)
    }

    /// Build a routing key for a `PATCH` route.
    static func patch(_ path: String) -> [String] {
        self.route(method: "PATCH", path: path)
    }

    /// The routing key used to dispatch this request. Symmetric with the static
    /// factories above — both go through `route(method:path:)`.
    ///
    /// Reads the HTTP method and proxy path from the underlying AWS event. The
    /// API Gateway HTTP integration places the matched URL path under the
    /// `proxy` path parameter when the route is configured as `/{proxy+}`.
    var routingKey: [String] {
        Self.route(
            method: self.event.context.http.method.rawValue,
            path: self.event.pathParameters["proxy"] ?? ""
        )
    }
}

// MARK: - HTTP typealiases

/// A `RouterBuilder` specialized for AWS Lambda HTTP requests, backed by a
/// `TrieRouter` engine.
public typealias HTTPRouterBuilder = RouterBuilder<
    HTTPRequest,
    TrieRouterBuilder<RouteHandler<HTTPRequest>>
>

/// An immutable `Router` specialized for AWS Lambda HTTP requests, produced by
/// calling `build()` on an `HTTPRouterBuilder`.
public typealias HTTPRouter = Router<HTTPRequest>

// MARK: - HTTP convenience init

public extension RouterBuilder where R == HTTPRequest,
    Engine == TrieRouterBuilder<RouteHandler<HTTPRequest>> {
    /// Construct an HTTP router builder backed by a default `TrieRouter` engine.
    convenience init() {
        self.init(engine: TrieRouterBuilder())
    }
}

// MARK: - RouterBuilder HTTP sugar

public extension RouterBuilder where R == HTTPRequest,
    Engine == TrieRouterBuilder<RouteHandler<HTTPRequest>> {
    /// Register a `GET` handler at the given path.
    func get(
        _ path: String,
        use handler: @Sendable @escaping (HTTPRequest, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.get(path), use: handler)
    }

    /// Register a `DELETE` handler at the given path.
    func delete(
        _ path: String,
        use handler: @Sendable @escaping (HTTPRequest, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.delete(path), use: handler)
    }
}

// MARK: - RouteGroup HTTP sugar

public extension RouteGroup where R == HTTPRequest,
    Engine == TrieRouterBuilder<RouteHandler<HTTPRequest>> {
    /// Register a `GET` handler at the given path, running this group's middleware first.
    func get(
        _ path: String,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.get(path), use: handler)
    }

    /// Register a `DELETE` handler at the given path, running this group's middleware first.
    func delete(
        _ path: String,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.delete(path), use: handler)
    }

    func post(
        _ path: String,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.post(path), use: handler)
    }

    /// Register a `POST` handler at the given path, running middleware and JSON-decoding
    /// the request body into `Body` before invoking the handler.
    func post<Body: Decodable & Sendable>(
        _ path: String,
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.post(path), body: body, use: handler)
    }

    /// Register a `PUT` handler at the given path, running middleware and JSON-decoding
    /// the request body into `Body` before invoking the handler.
    func put<Body: Decodable & Sendable>(
        _ path: String,
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.put(path), body: body, use: handler)
    }

    /// Register a `PATCH` handler at the given path, running this group's middleware first.
    func patch(
        _ path: String,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.patch(path), use: handler)
    }

    /// Register a `PATCH` handler at the given path, running middleware and JSON-decoding
    /// the request body into `Body` before invoking the handler.
    func patch<Body: Decodable & Sendable>(
        _ path: String,
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) {
        self.on(HTTPRequest.patch(path), body: body, use: handler)
    }
}
