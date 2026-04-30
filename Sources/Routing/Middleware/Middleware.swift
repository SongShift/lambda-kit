//
//  Middleware.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Logging

// MARK: - MiddlewareContext

/// A `@dynamicMemberLookup` wrapper that pairs a value produced by a middleware
/// (`value`) with the input it was derived from (`wrapped`). Both sides are
/// readable through subscript forwarding, so handlers can access fields off the
/// middleware's output and the original request without unwrapping.
@dynamicMemberLookup
public struct MiddlewareContext<Value: Sendable, Wrapped: Sendable>: Sendable {
    public let value: Value
    public let wrapped: Wrapped

    public init(_ value: Value, wrapping wrapped: Wrapped) {
        self.value = value
        self.wrapped = wrapped
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        self.value[keyPath: keyPath]
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Wrapped, T>) -> T {
        self.wrapped[keyPath: keyPath]
    }
}

// MARK: - Middleware (convenience refinement)

/// A convenience refinement of `MiddlewareProtocol` for the common case of
/// "produce a `Value` (or a short-circuit `Response`), and have the framework
/// auto-wrap it in a `MiddlewareContext`."
///
/// Conformers implement `process(_:logger:)`, which returns a
/// `MiddlewareAction<Value>`. The default `handle` implementation either
/// continues the chain with `MiddlewareContext(value, wrapping: input)` or
/// short-circuits with the supplied response.
public protocol Middleware: MiddlewareProtocol where Output == MiddlewareContext<Value, Input> {
    associatedtype Value: Sendable
    func process(_ input: Input, logger: Logger) async throws -> MiddlewareAction<Value>
}

public extension Middleware {
    func handle(
        _ input: Input,
        next: @Sendable (Output, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        switch try await process(input, logger: logger) {
        case let .next(value):
            return try await next(MiddlewareContext(value, wrapping: input), logger)
        case let .respond(response):
            return response
        }
    }
}
