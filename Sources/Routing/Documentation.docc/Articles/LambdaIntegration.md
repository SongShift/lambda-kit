# AWS Lambda integration

Drop-in support for API Gateway HTTP and WebSocket events.

## Overview

The library ships first-class transport adapters for the two AWS Lambda event
shapes that benefit most from routing:

  * ``HTTPRequest`` wraps `APIGatewayV2Request` and exposes typed `body`,
    `pathParameters`, `queryParameters`, and `headers` slots. Forwards every
    other field of the underlying event through `@dynamicMemberLookup`, so
    `req.context.stage` works without us having to surface every field
    manually.
  * ``WebSocketRequest`` wraps `APIGatewayWebSocketRequest` and behaves
    identically — typed conveniences on top, dynamic-member-lookup for the
    rest.

Both come with a constrained `RouterBuilder` and `RouteGroup` extension that
add transport-shaped sugar on top of the generic `on(_:use:)` API.

## HTTP

```swift
import AWSLambdaEvents
import Routing

let router: HTTPRouter = {
    let builder = HTTPRouterBuilder()
    builder.get("/health") { _, _ in .json(["status": "ok"], statusCode: .ok) }

    let authed = builder.withMiddleware { LoggingMiddleware(); AuthMiddleware() }
    authed.get("/sightings/:id") { context, _ in
        let id = try context.wrapped.pathParameters.require("id")
        return .json(["id": id], statusCode: .ok)
    }
    authed.post("/sightings", body: NewSighting.self) { context, body, _ in
        return .json(["created": body.id], statusCode: .created)
    }
    return builder.build()
}()
```

The HTTP routing key convention is `[METHOD, ...pathSegments]`, derived from
``HTTPRequest/route(method:path:)``. Static factories
(``HTTPRequest/get(_:)``, ``HTTPRequest/post(_:)``, etc.) build registration
keys; the dynamic ``HTTPRequest/routingKey-swift.property`` calls through to
the same function so registration and dispatch can never drift apart.

## WebSocket

```swift
import AWSLambdaEvents
import Routing

let router: WebSocketRouter = {
    let builder = WebSocketRouterBuilder()
    builder.connect { _, _ in .empty(statusCode: .ok) }
    builder.disconnect { _, _ in .empty(statusCode: .ok) }

    let authed = builder.withMiddleware { LoggingMiddleware(); AuthMiddleware() }
    authed.on("subscribe", body: SubscribePayload.self) { context, payload, _ in
        // process subscription
        return .empty(statusCode: .ok)
    }
    return builder.build()
}()
```

WebSocket routing uses ``DictionaryRouterBuilder`` because API Gateway
WebSocket route keys are flat string identifiers — no hierarchy, no path
parameters, no benefit from a trie. ``WebSocketRequest/connect()`` and
``WebSocketRequest/disconnect()`` build the framework `$connect` /
`$disconnect` keys so you don't have to remember the dollar-prefixed
literals.

## Wiring up the Lambda runtime

The `Router` is `Sendable` and immutable — build it once at cold-start and
share it across every invocation:

```swift
import AWSLambdaRuntime

@main
struct Handler {
    static let router = buildRouter()

    static func main() async throws {
        try await LambdaRuntime { (event: APIGatewayV2Request, ctx: LambdaContext) in
            let response = await router.handle(HTTPRequest(event: event), logger: ctx.logger)
            return APIGatewayV2Response(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body
            )
        }.run()
    }
}
```

The same shape works for WebSocket events — substitute `APIGatewayWebSocketRequest`
for `APIGatewayV2Request` and `WebSocketRequest(event:)` for
`HTTPRequest(event:)`.
