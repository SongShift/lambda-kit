//
//  MiddlewareProtocol.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Logging

// MARK: - Action

/// What a `Middleware`'s `process(_:logger:)` returns: either continue the chain
/// with a value, or short-circuit the entire pipeline with a fully-formed response.
public enum MiddlewareAction<Value: Sendable>: Sendable {
    case next(Value)
    case respond(RouteResponse)
}

// MARK: - Base Protocol

/// The composable base every middleware ultimately satisfies.
///
/// `MiddlewareProtocol` is intentionally low-level: a middleware receives an
/// `Input`, may invoke `next` with an `Output`, and produces a `Response`. It
/// makes no assumption about whether the middleware passes through, transforms,
/// short-circuits, or branches — those concerns are layered on top via the
/// `Middleware` convenience refinement and the combinators in
/// `MiddlewareCombinators.swift`.
public protocol MiddlewareProtocol<Input, Output>: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func handle(
        _ input: Input,
        next: @Sendable (Output, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse
}
