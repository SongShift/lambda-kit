# Composing middleware

Compose typed transformations and short-circuit checks that run before your handler.

## Overview

Middleware is the place to put cross-cutting concerns: authentication, request
logging, body decoding, request-ID stamping, rate limiting. The base
``MiddlewareProtocol`` is intentionally low-level — a middleware receives an
`Input`, may invoke `next` with an `Output`, and produces a ``RouteResponse`` —
which lets it pass through, transform, short-circuit, or branch.

For the most common case ("produce a value, or short-circuit with a response"),
the ``Middleware`` refinement gives you a smaller surface to implement:

```swift
struct AuthMiddleware: Middleware {
    typealias Input = APIRequest
    typealias Value = UserID

    func process(
        _ input: APIRequest,
        logger: Logger
    ) async throws -> MiddlewareAction<UserID> {
        guard let token = input.headers["Authorization"] else {
            return .respond(.error(statusCode: .unauthorized, message: "Missing token"))
        }
        return .next(try await verify(token))
    }
}
```

When the chain continues, the framework wraps your `Value` in a
``MiddlewareContext``: the wrapper exposes the value alongside the original
input, both forwarded through `@dynamicMemberLookup` so handlers can read
fields off either side.

## Composing chains

Two middlewares compose with `chain`:

```swift
let chain = LoggingMiddleware().chain(AuthMiddleware())
```

But the ``MiddlewareBuilder`` result builder reads better at registration sites:

```swift
builder.withMiddleware {
    LoggingMiddleware()
    AuthMiddleware()
}
.on(["GET", "users", ":id"]) { context, logger in
    // context.value is the AuthMiddleware's UserID Value
    // context.wrapped is the original APIRequest
    // ...
}
```

`withMiddleware` returns a ``RouteGroup`` whose registrations all run through
the chain. You can extend a group with more middleware via
``RouteGroup/withMiddleware(_:)`` — the new group's handlers receive the
chained middleware's final output type.

## Combinators

  * ``ChainedMiddleware`` — runs `A` then `B` (`A.Output == B.Input`).
  * ``OptionalMiddleware`` — passthrough when its wrapped middleware is `nil`.
  * ``EitherMiddleware`` — selects one of two middlewares with the same shape;
    typically produced by `MiddlewareBuilder`'s `if/else` branches.
  * ``MappedMiddleware`` / `.map` — post-processes a middleware's output with a
    pure function, producing a new output type. Useful for adapting one
    middleware's output to fit the next middleware's input.

## Patterns

**Body decoding.** The router has a built-in `on(_:through:body:use:)`
overload on ``RouterBuilder`` that JSON-decodes the request body before
invoking the handler. For more elaborate decoding (versioned
payloads, content negotiation), write a `Middleware` whose `Value` is the
decoded payload.

**Request-scoped logging.** Stamp a request ID onto the `Logger` metadata in a
middleware, and every downstream handler and middleware will see it. The
demo's `RequestIDMiddleware` is a one-screen example.

**Conditional auth.** Use ``MiddlewareBuilder``'s `buildOptional` /
`buildEither` to wrap auth around some routes but not others — or branch
between two auth flows depending on a header.
