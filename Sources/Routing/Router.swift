//
//  Router.swift
//
//  Created by Ben Rosen on 4/6/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Foundation
import Logging
import RoutingKit

/// The handler signature stored at every routing key for `Routable` `R`.
public typealias RouteHandler<R: Routable> = @Sendable (R, Logger) async throws -> RouteResponse

// MARK: - RouterBuilder (registration phase)

/// Accumulates handlers for `Routable` requests and produces an immutable `Router`
/// for dispatch.
///
/// `RouterBuilder` is transport- and engine-agnostic. It knows nothing about HTTP
/// methods, URL paths, WebSocket route keys, or any concrete request shape. It only
/// knows how to register a handler at a `[String]` routing key. Transport-specific
/// conventions live on the `Routable` type itself; engine-specific behavior (trie
/// vs. dictionary lookup, partial parameters, case sensitivity) lives in the
/// underlying `RoutingKit.RouterBuilder` you inject as `Engine`.
///
/// `RouterBuilder` is intentionally non-`Sendable`: registration is expected to
/// complete on a single isolation domain before `build()` is called. The `Router`
/// returned by `build()` is immutable and `Sendable`, so dispatch can freely cross
/// actor boundaries.
public final class RouterBuilder<R: Routable, Engine: RoutingKit.RouterBuilder>
    where Engine.Output == RouteHandler<R>,
    Engine.Router.Output == RouteHandler<R> {
    private var engine: Engine

    /// Construct a builder backed by an explicit routing engine. Most call sites
    /// should use the transport-specific convenience initializers (e.g.
    /// `HTTPRouterBuilder()`, `WebSocketRouterBuilder()`) rather than calling
    /// this directly.
    public init(engine: Engine) {
        self.engine = engine
    }

    // MARK: - Direct routes

    /// Register a handler at a routing key.
    ///
    /// The key is an array of trie segments. Segments may be literal strings or
    /// parameter patterns recognized by `RoutingKit.PathComponent` (e.g. `":id"`,
    /// `"*"`, `"**"`). Whether multi-segment, parameterized, or wildcard keys are
    /// actually supported depends on the underlying engine.
    public func on(
        _ key: [String],
        use handler: @Sendable @escaping (R, Logger) async throws -> RouteResponse
    ) {
        let components = key.map { PathComponent(stringLiteral: $0) }
        do {
            try self.engine.register(handler, at: components)
        } catch {
            preconditionFailure("Failed to register route at \(key): \(error)")
        }
    }

    // MARK: - Routes through middleware

    /// Register a handler at a routing key, running it through middleware first.
    public func on<M: MiddlewareProtocol>(
        _ key: [String],
        through middleware: M,
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) where M.Input == R {
        self.on(key) { request, logger in
            try await middleware.handle(request, next: handler, logger: logger)
        }
    }

    /// Register a handler at a routing key, running middleware and then JSON-decoding
    /// the request body into `Body` before invoking the handler.
    ///
    /// Available for any `Routable` whose `body: Data` carries JSON. The HTTP and
    /// WebSocket adapters both qualify.
    public func on<M: MiddlewareProtocol, Body: Decodable & Sendable>(
        _ key: [String],
        through middleware: M,
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) where M.Input == R {
        self.on(key) { request, logger in
            try await middleware.handle(request, next: { output, logger in
                let decoded = try JSONDecoder().decode(Body.self, from: request.body)
                return try await handler(output, decoded, logger)
            }, logger: logger)
        }
    }

    // MARK: - Groups

    /// Begin a route group whose registrations all run through the supplied middleware.
    public func withMiddleware<M: MiddlewareProtocol>(
        @MiddlewareBuilder _ build: () -> M
    ) -> RouteGroup<R, Engine, M> where M.Input == R {
        RouteGroup(builder: self, middleware: build())
    }

    // MARK: - Build

    /// Finalize this builder into an immutable, dispatch-ready `Router`.
    ///
    /// After calling `build()`, this builder should not be used further.
    public func build() -> Router<R> {
        Router(engine: self.engine.build())
    }
}

// MARK: - Router (dispatch phase, immutable)

/// An immutable, `Sendable` router produced by `RouterBuilder.build()`.
///
/// `Router` is type-erased over its underlying `RoutingKit.Router` engine: all
/// engines look identical from the outside, and the engine choice is invisible to
/// dispatch callers. Registration is the `RouterBuilder`'s job, so the type system
/// enforces that no routes can be added after dispatch begins.
public final class Router<R: Routable>: Sendable {
    private let lookup: @Sendable ([String], inout RoutingKit.Parameters) -> RouteHandler<R>?

    init<Engine: RoutingKit.Router>(engine: Engine) where Engine.Output == RouteHandler<R> {
        self.lookup = { path, parameters in
            engine.route(path: path, parameters: &parameters)
        }
    }

    /// Dispatch a request to its registered handler.
    ///
    /// Returns a 404 `Response` if no handler matches. Returns a 500 `Response` if
    /// the handler throws an unhandled error — use an error-handling middleware to
    /// translate domain errors into responses before they reach this fallback.
    public func handle(_ request: R, logger: Logger) async -> Response {
        var routingParams = RoutingKit.Parameters()

        guard let handler = self.lookup(request.routingKey, &routingParams) else {
            return .error(statusCode: .notFound, message: "Not found")
        }

        var request = request
        var pathParameters = PathParameters()
        for name in routingParams.allNames {
            if let value = routingParams.get(name) {
                pathParameters.set(name, to: value)
            }
        }
        request.pathParameters = pathParameters

        do {
            let routeResponse = try await handler(request, logger)
            return try routeResponse.encoded()
        } catch let error as PathParameterError {
            return .error(statusCode: .badRequest, message: error.message)
        } catch let error as QueryParameterError {
            return .error(statusCode: .badRequest, message: error.message)
        } catch let error as HeaderError {
            return .error(statusCode: .badRequest, message: error.message)
        } catch {
            return .error(statusCode: .internalServerError, message: "Internal server error")
        }
    }
}

// MARK: - Route Group

/// A group of routes that all run through a shared middleware chain.
///
/// `RouteGroup` is the typed-middleware machinery: registrations made on the group
/// receive `M.Output` (the type produced by the middleware chain), not the raw
/// request. This gives compile-time guarantees that handlers cannot run without
/// their declared middleware having succeeded.
public final class RouteGroup<R: Routable, Engine: RoutingKit.RouterBuilder, M: MiddlewareProtocol>
    where Engine.Output == RouteHandler<R>,
    Engine.Router.Output == RouteHandler<R>,
    M.Input == R {
    let builder: RouterBuilder<R, Engine>
    let middleware: M

    init(builder: RouterBuilder<R, Engine>, middleware: M) {
        self.builder = builder
        self.middleware = middleware
    }

    /// Register a handler at a routing key, running this group's middleware first.
    public func on(
        _ key: [String],
        use handler: @Sendable @escaping (M.Output, Logger) async throws -> RouteResponse
    ) {
        self.builder.on(key, through: self.middleware, use: handler)
    }

    /// Register a handler at a routing key, running middleware and then JSON-decoding
    /// the request body into `Body` before invoking the handler.
    public func on<Body: Decodable & Sendable>(
        _ key: [String],
        body: Body.Type,
        use handler: @Sendable @escaping (M.Output, Body, Logger) async throws -> RouteResponse
    ) {
        self.builder.on(key, through: self.middleware, body: body, use: handler)
    }

    /// Extend this group with additional middleware. The new group's handlers receive
    /// the chained middleware's final `Output` type.
    public func withMiddleware<N: MiddlewareProtocol>(
        @MiddlewareBuilder _ build: () -> N
    ) -> RouteGroup<R, Engine, ChainedMiddleware<M, N>> where M.Output == N.Input {
        RouteGroup<R, Engine, ChainedMiddleware<M, N>>(
            builder: self.builder,
            middleware: self.middleware.chain(build())
        )
    }
}
