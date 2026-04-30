//
//  MiddlewareCombinators.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

//  Combinators that compose `MiddlewareProtocol` values into new ones:
//
//    - `ChainedMiddleware` runs two middlewares in sequence (`A` then `B`).
//    - `OptionalMiddleware` is a passthrough when its wrapped middleware is nil.
//    - `EitherMiddleware` selects one of two middlewares with the same shape.
//    - `MappedMiddleware` post-processes a middleware's output with a pure
//      function, producing a new output type.
//
//  Each combinator is a thin struct over its inputs; the only "smart" piece is
//  the `handle` implementation that wires `next` callbacks together.
//

import Logging

// MARK: - Chain

public struct ChainedMiddleware<A: MiddlewareProtocol, B: MiddlewareProtocol>: MiddlewareProtocol
    where A.Output == B.Input {
    let first: A
    let second: B

    public func handle(
        _ input: A.Input,
        next: @Sendable (B.Output, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        try await self.first.handle(input, next: { output, logger in
            try await self.second.handle(output, next: next, logger: logger)
        }, logger: logger)
    }
}

public extension MiddlewareProtocol {
    func chain<M: MiddlewareProtocol>(
        _ next: M
    ) -> ChainedMiddleware<Self, M> where Output == M.Input {
        ChainedMiddleware(first: self, second: next)
    }
}

// MARK: - Optional (passthrough when nil)

public struct OptionalMiddleware<M: MiddlewareProtocol>: MiddlewareProtocol
    where M.Output == M.Input {
    let middleware: M?

    public func handle(
        _ input: M.Input,
        next: @Sendable (M.Input, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        if let middleware {
            return try await middleware.handle(input, next: next, logger: logger)
        }
        return try await next(input, logger)
    }
}

// MARK: - Either (branching)

public struct EitherMiddleware<A: MiddlewareProtocol, B: MiddlewareProtocol>: MiddlewareProtocol
    where A.Input == B.Input, A.Output == B.Output {
    enum Storage: Sendable { case left(A), right(B) }
    let storage: Storage

    public func handle(
        _ input: A.Input,
        next: @Sendable (A.Output, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        switch self.storage {
        case let .left(a): return try await a.handle(input, next: next, logger: logger)
        case let .right(b): return try await b.handle(input, next: next, logger: logger)
        }
    }
}

// MARK: - Map (transform output with a pure function)

public struct MappedMiddleware<Base: MiddlewareProtocol, NewOutput: Sendable>: MiddlewareProtocol {
    let base: Base
    let transform: @Sendable (Base.Output) -> NewOutput

    public func handle(
        _ input: Base.Input,
        next: @Sendable (NewOutput, Logger) async throws -> RouteResponse,
        logger: Logger
    ) async throws -> RouteResponse {
        try await self.base.handle(input, next: { output, logger in
            try await next(self.transform(output), logger)
        }, logger: logger)
    }
}

public extension MiddlewareProtocol {
    func map<NewOutput: Sendable>(
        _ transform: @Sendable @escaping (Output) -> NewOutput
    ) -> MappedMiddleware<Self, NewOutput> {
        MappedMiddleware(base: self, transform: transform)
    }
}
