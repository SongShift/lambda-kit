//
//  DictionaryRouter.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

//  A flat-key routing engine for transports whose route names are single
//  identifiers rather than hierarchical paths (e.g. AWS API Gateway WebSocket
//  routes, where each message has a single `routeKey` like `subscribe` or
//  `$connect`). It exists as a deliberate alternative to `TrieRouter` so that
//  WebSocket routing isn't forced through a trie that's designed for
//  multi-segment URL paths.
//
//  This file conforms to the `RoutingKit.Router` and `RoutingKit.RouterBuilder`
//  protocols so that it can plug into our generic `RouterBuilder<R, Engine>` as
//  the `Engine` parameter, identically to how `TrieRouter` does.

import RoutingKit

// MARK: - DictionaryRouterBuilder

/// A `RoutingKit.RouterBuilder` that registers handlers under a single literal
/// path segment. Multi-segment, parameter, and wildcard paths are all rejected
/// at registration time, since this engine has no concept of hierarchy.
public struct DictionaryRouterBuilder<Output: Sendable>: RoutingKit.RouterBuilder {
    private var routes: [String: Output] = [:]

    public init() {}

    /// Register a handler under a single literal path segment.
    ///
    /// Throws `DictionaryRouterError.unsupportedPath` if `path` is not exactly one
    /// `.constant` segment.
    public mutating func register(_ output: Output, at path: [PathComponent]) throws {
        guard path.count == 1, case let .constant(key) = path[0] else {
            throw DictionaryRouterError.unsupportedPath(path)
        }
        self.routes[key] = output
    }

    public func build() -> DictionaryRouter<Output> {
        DictionaryRouter(routes: self.routes)
    }
}

// MARK: - DictionaryRouter

/// An immutable `RoutingKit.Router` backed by a `[String: Output]` lookup. Matches
/// only single-segment paths against literal keys. Path parameters are never
/// populated because this engine doesn't support them.
public struct DictionaryRouter<Output: Sendable>: RoutingKit.Router {
    let routes: [String: Output]

    public func route(path: [String], parameters: inout RoutingKit.Parameters) -> Output? {
        guard path.count == 1 else { return nil }
        return self.routes[path[0]]
    }
}

// MARK: - Errors

public enum DictionaryRouterError: Error {
    case unsupportedPath([PathComponent])
}
