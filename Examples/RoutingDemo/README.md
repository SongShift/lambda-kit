# RoutingDemo

A focused demo of the `Routing` library configured as a real AWS Lambda.
Registers a small trail-log API against the Lambda transport types
(`HTTPRequest`, `HTTPRouterBuilder`) and runs as a `LambdaRuntime`, ready to
be packaged and deployed behind API Gateway.

```sh
swift build --target RoutingDemo
```

Running the executable directly only makes sense inside a Lambda environment
(or with the `swift-aws-lambda-runtime` local-server trait enabled — see the
runtime's docs); this README focuses on the routing wire-up.

## What's wired up

`main.swift` registers four routes:

  * `GET /health` — public, no middleware.
  * `GET /hikes/:id` — runs through `LoggingMiddleware` then
    `AuthMiddleware`, looks up a hike in the in-memory `HikeStore`.
  * `POST /hikes` — same middleware chain, plus body decoding into a
    `NewHike` payload before invoking the handler.
  * Anything else returns `404` from the router's fallback.

The two middlewares live in [`Middleware.swift`](Sources/Middleware.swift):

  * `LoggingMiddleware` is a passthrough — it logs the request and response
    without changing the input shape.
  * `AuthMiddleware` is a stub that always succeeds with a fixed
    `HikerID`. A production version would verify a JWT (or similar) and
    short-circuit with `401` on failure.

## Lambda wiring

The runtime is set up exactly the way a real Lambda function would be:

```swift
let runtime = LambdaRuntime {
    (event: APIGatewayV2Request, context: LambdaContext) async -> APIGatewayV2Response in
    let response = await router.handle(HTTPRequest(event: event), logger: context.logger)
    return APIGatewayV2Response(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body
    )
}

try await runtime.run()
```

The router is built once at cold-start and reused across every invocation —
`HTTPRouter` is `Sendable` and immutable, so concurrent invocations are safe.
