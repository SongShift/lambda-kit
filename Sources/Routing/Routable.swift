//
//  Routable.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Foundation

/// A type that can be routed through a `Router`.
///
/// Conform your transport-specific request type (HTTP request, WebSocket event, queue
/// message, etc.) to `Routable` to use it with `Router<Self>`. The router uses
/// `routingKey` to dispatch to a registered handler, then injects matched path
/// parameters into `pathParameters` before invoking middleware.
public protocol Routable: Sendable {
    /// The trie path segments used to dispatch this request to a handler.
    ///
    /// For an HTTP request this is typically `[method, ...pathSegments]`. For a
    /// WebSocket event it might be `[routeKey]`. The router compares this against
    /// registered routes to find a handler.
    var routingKey: [String] { get }

    /// Path parameters matched during routing. The router writes to this property
    /// after a successful trie lookup; handlers and middleware read from it.
    var pathParameters: PathParameters { get set }

    /// The request body. Used by body-decoding route registrations. Return an empty
    /// `Data` if your transport has no body concept.
    var body: Data { get }
}
