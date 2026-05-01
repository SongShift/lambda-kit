# Routing engines

Pick the matching algorithm that fits your transport.

## Overview

The ``RouterBuilder`` is parameterized over a `RoutingKit.RouterBuilder`, so
the actual matching algorithm is pluggable. The two engines that ship with
this library are deliberately tuned for two different shapes of incoming
event.

### TrieRouter (HTTP)

`TrieRouterBuilder` from `RoutingKit` matches multi-segment paths with `:id`
parameters and `*`/`**` wildcards. This is the right engine for HTTP routing,
where a request's `routingKey` looks like `[method, ...pathSegments]`:

```swift
let builder = Routing.RouterBuilder<HTTPRequest, TrieRouterBuilder<RouteHandler<HTTPRequest>>>(
    engine: TrieRouterBuilder()
)
builder.on(["GET", "users", ":id", "comments"]) { request, _ in
    let id = try request.pathParameters.require("id")
    // ...
}
```

The trie populates ``PathParameters`` with the matched segment value for
every `:name` placeholder.

### DictionaryRouter (WebSocket / queue)

``DictionaryRouterBuilder`` registers handlers under a single literal key.
It's designed for transports whose route names are single, opaque
identifiers — most notably AWS API Gateway WebSocket events, where each
message has one `routeKey` (`$connect`, `$disconnect`, `subscribe`, etc.):

```swift
let builder = Routing.RouterBuilder<WebSocketEvent, DictionaryRouterBuilder<RouteHandler<WebSocketEvent>>>(
    engine: DictionaryRouterBuilder()
)
builder.on(["subscribe"]) { event, _ in /* ... */ }
builder.on(["$connect"]) { event, _ in /* ... */ }
```

Multi-segment, parameterized, and wildcard keys are all rejected at
registration time with ``DictionaryRouterError/unsupportedPath(_:)``. There
are no path parameters to populate — there are no segments to match.

## Choosing

  * Use the trie engine for HTTP, queue messages keyed by hierarchical names,
    or anything else where a request maps to a sequence of segments that
    might include parameters or wildcards.
  * Use the dictionary engine for transports whose route names are opaque
    single tokens. Faster lookup for that case, and the registration-time
    rejection of multi-segment paths catches mistakes early.

## Bringing your own engine

`RouterBuilder` is generic over any `RoutingKit.RouterBuilder` whose
`Output == RouteHandler<R>`. If you have a more exotic dispatch policy
(e.g. trie + suffix matching, regex routes, or a routing table backed by
external configuration), conform your engine to `RoutingKit.RouterBuilder`
and `RoutingKit.Router` and plug it in identically to the engines above.
