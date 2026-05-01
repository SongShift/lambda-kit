# ``Routing``

A typed, middleware-aware request router for AWS Lambda — and any other
transport you care to plug in.

## Overview

The `Routing` library dispatches incoming requests to handlers registered
against routing keys. It ships first-class adapters for the two AWS Lambda
event shapes that benefit most from routing — API Gateway HTTP and
WebSocket — and a transport-agnostic core you can plug any other request
type into.

Middleware can transform the request before it reaches the handler, with the
type system guaranteeing that handlers cannot run unless the middleware that
produces their inputs has run first.

```swift
import AWSLambdaEvents
import AWSLambdaRuntime
import Routing

let router: HTTPRouter = {
    let builder = HTTPRouterBuilder()
    builder.get("/health") { _, _ in .json(["status": "ok"], statusCode: .ok) }

    let authed = builder.withMiddleware { LoggingMiddleware(); AuthMiddleware() }
    authed.get("/sightings/:id") { context, _ in
        let id = try context.wrapped.pathParameters.require("id")
        return .json(["id": id], statusCode: .ok)
    }
    return builder.build()
}()

@main
struct Handler {
    static func main() async throws {
        try await LambdaRuntime { (event: APIGatewayV2Request, ctx: LambdaContext) in
            let response = await router.handle(HTTPRequest(event: event), logger: ctx.logger)
            return APIGatewayV2Response(statusCode: response.statusCode, body: response.body)
        }.run()
    }
}
```

The library is split into three concerns:

  * **Routing keys.** A request's ``Routable/routingKey`` is the array of
    segments the engine matches against. The trie engine treats it as a path;
    the dictionary engine treats it as a single literal.
  * **Handlers.** A handler is `(R, Logger) async throws -> RouteResponse`.
    The router type-erases its engine and exposes ``Router/handle(_:logger:)``,
    which translates a handler's `RouteResponse` into a wire-ready ``Response``.
  * **Middleware.** Implementations of ``MiddlewareProtocol`` that compose
    via the ``ChainedMiddleware``, ``OptionalMiddleware``, ``EitherMiddleware``,
    and ``MappedMiddleware`` combinators (or the ``MiddlewareBuilder`` result
    builder).

> Note: For Lambda wiring details, see <doc:LambdaIntegration>. For more on
> building middleware chains, see <doc:ComposingMiddleware>. For routing-engine
> choices, see <doc:Engines>.

## Quick start

For Lambda, build the router once at cold-start and reuse it across every
invocation:

```swift
let router: HTTPRouter = {
    let builder = HTTPRouterBuilder()
    builder.get("/sightings/:id") { request, _ in
        let id = try request.pathParameters.require("id")
        return .json(["id": id], statusCode: .ok)
    }
    return builder.build()
}()
```

`HTTPRouterBuilder` and ``HTTPRouter`` are typealiases for the generic
``RouterBuilder`` and ``Router`` parameterized over ``HTTPRequest`` and a
`TrieRouter` engine. If you have a different transport — a WebSocket router,
a queue dispatcher, anything where requests can be keyed — conform your
request type to ``Routable`` and use ``RouterBuilder`` directly:

```swift
struct QueueMessage: Routable {
    let action: String
    let body: Data
    var pathParameters = PathParameters()
    var routingKey: [String] { [action] }
}
```

## Topics

### Essentials

- <doc:LambdaIntegration>
- <doc:ComposingMiddleware>
- <doc:Engines>

### AWS Lambda transports

- ``HTTPRequest``
- ``HTTPRouter``
- ``HTTPRouterBuilder``
- ``WebSocketRequest``
- ``WebSocketRouter``
- ``WebSocketRouterBuilder``

### Defining requests

- ``Routable``
- ``PathParameters``
- ``QueryParameters``
- ``Headers``

### Building and dispatching

- ``RouterBuilder``
- ``Router``
- ``RouteGroup``
- ``RouteHandler``

### Producing responses

- ``RouteResponse``
- ``Response``

### Middleware

- ``MiddlewareProtocol``
- ``Middleware``
- ``MiddlewareAction``
- ``MiddlewareContext``
- ``MiddlewareBuilder``
- ``ChainedMiddleware``
- ``OptionalMiddleware``
- ``EitherMiddleware``
- ``MappedMiddleware``

### Routing engines

- ``DictionaryRouterBuilder``
- ``DictionaryRouter``
- ``DictionaryRouterError``

### Errors

- ``PathParameterError``
- ``QueryParameterError``
- ``HeaderError``
