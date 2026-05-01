# LambdaKit

**LambdaKit is a toolkit for writing AWS Lambda services in Swift.** It pairs
a typed request router built around the API Gateway HTTP and WebSocket event
shapes with a typed DynamoDB query DSL, so the entire request → handler →
DynamoDB lifecycle can be expressed without leaving the type system.

The two libraries ship independently — pull in only what your function needs:

  * **Routing** — a middleware-aware request router with first-class
    `APIGatewayV2Request` / `APIGatewayWebSocketRequest` transports. The
    router you build is `Sendable`, dispatched by a single `LambdaRuntime`
    handler, and reused across every invocation.
  * **DynamoQueries** — a typed query DSL for DynamoDB with macros that lift
    your table schema into the type system.

Drop both into a Lambda and the cold-start path is short, the per-invocation
path is allocation-light, and the type checker catches mistakes that would
otherwise show up as runtime `400`/`500`s.

```swift
import AWSLambdaEvents
import AWSLambdaRuntime
import Routing

let router: HTTPRouter = {
    let builder = HTTPRouterBuilder()
    builder.get("/hikes/:id") { request, _ in
        let id = try request.pathParameters.require("id")
        return .json(["id": id], statusCode: .ok)
    }
    return builder.build()
}()

@main
struct Handler {
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

  * [Overview](#overview)
  * [Routing](#routing)
    * [Quick start](#quick-start-routing)
    * [Middleware](#middleware)
    * [Path, query, and header parameters](#parameters)
    * [Engines](#engines)
  * [DynamoQueries](#dynamoqueries)
    * [Quick start](#quick-start-dynamoqueries)
    * [Querying and scanning](#querying-and-scanning)
    * [Writes and conditional checks](#writes-and-conditional-checks)
    * [Updates](#updates)
    * [Batch and transactional writes](#batch-and-transactional-writes)
    * [Pagination](#pagination)
    * [Soto adapter](#soto-adapter)
  * [Demos](#demos)
  * [Documentation](#documentation)
  * [Installation](#installation)
  * [License](#license)

## Overview

LambdaKit is built around the shape of a Swift Lambda function: build the
router (and any other expensive state) once at cold-start, then let
`LambdaRuntime` dispatch every invocation through it.

  * Use just `Routing` for a Lambda that only needs to dispatch HTTP or
    WebSocket events to handlers.
  * Use just `DynamoQueries` (and `DynamoQueriesSoto`) for a worker Lambda or
    a non-Lambda app that talks to DynamoDB.
  * Use both together for an HTTP-fronted, DynamoDB-backed service — the
    canonical Lambda shape.

Both libraries lean on Swift's type system and result builders to keep call
sites short while preserving compile-time guarantees: middleware outputs flow
to handlers via the type checker; DynamoDB attributes are typed by the schema
your `@Table` struct declares.

---

## Routing

`Routing` is built around the AWS Lambda HTTP and WebSocket event shapes.
``HTTPRequest`` wraps `APIGatewayV2Request`; ``WebSocketRequest`` wraps
`APIGatewayWebSocketRequest`. Both expose typed `body` / `pathParameters` /
`queryParameters` / `headers` slots and forward every other field through
`@dynamicMemberLookup`, so your handlers see the full AWS event surface
without you having to surface each field manually.

The router itself — `HTTPRouter` / `WebSocketRouter` — is `Sendable` and
immutable, built once at cold-start and reused across every invocation. A
typed middleware chain runs before each handler, with the type system
guaranteeing handlers cannot run unless their declared middleware succeeded.

For non-Lambda transports (queue dispatchers, custom HTTP servers, etc.) the
underlying `RouterBuilder` is generic — see [Engines](#engines) for the
escape hatch.

### <a name="quick-start-routing"></a>Quick start

The Lambda example at the top of this README shows the full cold-start →
runtime → dispatch shape. The pieces it composes:

  * **`HTTPRouterBuilder`** — registers handlers under method+path keys.
    Sugar methods (`get`, `post(_:body:)`, `patch`, etc.) cover the common
    cases; the underlying `on(_:use:)` takes any `[String]` routing key.
  * **`HTTPRouter`** — the immutable, `Sendable` router produced by
    `builder.build()`. Cold-start cost only; every invocation reuses it.
  * **`HTTPRequest(event:)`** — wraps the incoming `APIGatewayV2Request`
    with typed accessors (`headers`, `pathParameters`, `queryParameters`,
    `body`) and `@dynamicMemberLookup` forwarding for everything else.
  * **`router.handle(_:logger:)`** — dispatches one request, returns a
    wire-ready `Response` you translate into an `APIGatewayV2Response`.

Unmatched routes return `404`, unhandled errors return `500`, and the typed
parameter errors (`PathParameterError`, `QueryParameterError`, `HeaderError`)
are translated to `400` automatically.

For a transport other than API Gateway HTTP, conform your request type to
`Routable` and use the generic `RouterBuilder` directly — see
[Engines](#engines).

### Middleware

`Middleware` types transform a request — authenticating it, decoding a body,
loading a session — and pass an `Output` value down the chain. The output's
type appears in the handler's signature, so a handler cannot run unless the
middleware that produces its inputs has run first.

```swift
struct AuthMiddleware: Middleware {
    typealias Input = HTTPRequest
    typealias Value = HikerID

    func process(_ input: HTTPRequest, logger: Logger) async throws -> MiddlewareAction<HikerID> {
        guard let token = input.headers["authorization"] else {
            return .respond(.error(statusCode: .unauthorized, message: "Missing token"))
        }
        return .next(try await verify(token))
    }
}
```

Group routes under a shared chain with `withMiddleware`:

```swift
let authed = builder.withMiddleware { LoggingMiddleware(); AuthMiddleware() }

authed.get("/me") { context, _ in
    // `context.value` is the HikerID produced by AuthMiddleware.
    // `context.wrapped` is the original HTTPRequest.
    return .json(["hiker": context.value], statusCode: .ok)
}
```

Middleware chains compose with `chain`, the `MiddlewareBuilder` result builder,
and the `Optional`/`Either`/`Mapped` combinators in
`MiddlewareCombinators.swift`.

#### JSON body decoding

For routes that take a JSON body, register with `body:` to have the framework
decode the body before invoking the handler:

```swift
struct NewHike: Decodable & Sendable { let id: String; let trailName: String }

authed.post("/hikes", body: NewHike.self) { context, body, _ in
    return .json(["created": body.id], statusCode: .created)
}
```

### <a name="parameters"></a>Path, query, and header parameters

`PathParameters`, `QueryParameters`, and `Headers` all share the same shape:

```swift
let id = try request.pathParameters.require("id", as: UUID.self)
let cursor = request.queryParameters.get("cursor")
let agent = try request.headers.require("User-Agent")
```

The typed `as:` overloads accept any `LosslessStringConvertible`. Query
parameters also support `RawRepresentable` (for string-backed enums) and
`CodingKey`-based access. Headers are case-insensitive — `headers["Host"]`
and `headers["host"]` hit the same slot.

### Engines

Routing is parameterized over a `RoutingKit.RouterBuilder`, so the underlying
matching algorithm is pluggable:

  * **`TrieRouterBuilder`** (from `RoutingKit`) — multi-segment paths with `:id`
    parameters and `*`/`**` wildcards. The right choice for HTTP.
  * **``DictionaryRouterBuilder``** — single-segment, literal-only lookup.
    Designed for AWS API Gateway WebSocket routes (`$connect`, `subscribe`, etc.)
    where each event has a single, opaque route key.

---

## DynamoQueries

`DynamoQueries` lets you describe DynamoDB operations against typed Swift
models. The `@Table` macro lifts your table's primary key, attributes, and
secondary indexes into the type system, so query and update expressions are
checked at compile time and rendered into DynamoDB-correct expression strings
at runtime.

### <a name="quick-start-dynamoqueries"></a>Quick start

Declare a table with the `@Table` macro:

```swift
import DynamoQueries

@Table("Users")
@Index("emailIndex", partitionKey: "email")
struct User: Codable {
    @PartitionKey var id: String
    var email: String
    var displayName: String
    var createdAt: Date
    var isVerified: Bool = false
}
```

The macro generates:

  * A ``DynamoModel`` conformance.
  * A `Columns` struct (one ``Attribute`` per declared property), surfaced
    through the closure parameter on `query`/`scan`/`update`/etc.
  * A nested `Indexes` namespace with one ``Index`` instance per `@Index`.

Issue a query:

```swift
let client: any DynamoClient = SotoDynamoClient(database: dynamoDB)

let firstPage = try await User
    .query { user in
        Key { user.id == "user-123" }
    }
    .limit(20)
    .execute(using: client)

for user in firstPage.items { /* ... */ }
```

The `Key { ... }` block describes the primary key condition; `Filter { ... }`
is its post-fetch sibling. Inside both, you write Swift comparison operators
against the `Columns` proxy — they compile to `attributeName OP :value`
DynamoDB expressions with placeholders allocated for you.

### Querying and scanning

```swift
// Query a partition with a sort-key prefix:
try await Order.query { o in
    Key {
        o.customerID == "cust-1"
        o.orderID.beginsWith("2026-")
    }
    Filter {
        o.status != "cancelled"
        o.total > 100
    }
}
.executeAll(using: client)

// Query a secondary index, descending:
try await Order.query { o in
    Key { o.customerID == "cust-1" }
}
.on(Order.Indexes.byCreatedAt)
.scanIndexForward(false)
.limit(50)
.execute(using: client)

// Scan with a filter (use sparingly — scans bill for the unfiltered read):
try await Order.scan { o in
    o.status == "pending"
}
.executeAll(using: client)
```

Filter and key-condition blocks support a rich set of operators on each
`Attribute<T>`:

| Operator                                    | DynamoDB                                |
| ------------------------------------------- | --------------------------------------- |
| `==`, `!=`, `<`, `<=`, `>`, `>=`            | Comparison                              |
| `.between(_:and:)`                          | `BETWEEN`                               |
| `.beginsWith(_:)`                           | `begins_with`                           |
| `.contains(_:)`                             | `contains` (string, list, or set)       |
| `.exists` / `.doesNotExist`                 | `attribute_exists` / `attribute_not_exists` |
| `.size > N`, `.size.between(_:and:)`        | `size(path) OP :value`                  |
| `&&` / `\|\|` / `!`                         | Compound expressions                    |

### Writes and conditional checks

```swift
// Unconditional put:
try await user.put().execute(using: client)

// Insert-only-if-not-present (canonical "create" guard):
try await user.put { u in u.id.doesNotExist }.execute(using: client)

// Catch the prior item on conflict:
do {
    try await user
        .put { u in u.id.doesNotExist }
        .returnConflictingItem()
        .execute(using: client)
} catch let conflict as ConditionalCheckFailed<User> {
    let existing = conflict.priorItem  // decoded as User?
}
```

The `where:` block on `put`, `update`, and `delete` is a
``ConditionBuilder`` — same rules as `Filter`, but it gates the write rather
than the response.

### Updates

```swift
try await User.update(
    partitionKey: "user-123",
    {
        $0.displayName.set(to: "Ada")
        $0.isVerified.set(to: true)
        $0.createdAt.setIfNotExists(.now)
    },
    where: { $0.id.exists }
)
.execute(using: client)
```

Atomic counters (`add`), list `append`/`prepend`, set element add/remove,
and `remove` are all available on `Attribute`. Want the row back?

```swift
let updated = try await User.update(
    partitionKey: "user-123",
    { $0.loginCount.add(1) }
)
.returnNewValues()
.execute(using: client)
// updated: User?
```

### Batch and transactional writes

Batch writes (up to 25 items per request, single table):

```swift
try await User.batchWrite()
    .put(userA)
    .put(userB)
    .delete(partitionKey: "user-deprecated")
    .execute(using: client)
```

Transactional writes (up to 100 items, multi-table, all-or-nothing):

```swift
try await TransactWriteInput {
    user.put { $0.id.doesNotExist }
    try Account.update(partitionKey: user.id) { $0.userCount.add(1) }
    try AuditLog.conditionCheck(partitionKey: "system") { $0.frozen != true }
}
.execute(using: client)
```

A failed transaction throws ``TransactionCanceled`` whose `cancellations`
array maps 1:1 to the legs you submitted, with `code`/`message` per leg.

### Pagination

Single page, opaque cursor in the response:

```swift
let page = try await Order.query { ... }.execute(using: client)
let nextCursor = page.nextToken?.stringValue  // safe to embed in a JSON response
```

Resume on the next request:

```swift
let token = PaginationToken(string: clientCursor)
let page = try await Order.query { ... }.startToken(token).execute(using: client)
```

Stream every page lazily:

```swift
for try await page in Order.query { ... }.pages(using: client) {
    process(page.items)
}
```

Or load everything (be aware of memory for unbounded result sets):

```swift
let all = try await Order.query { ... }.executeAll(using: client)
```

`Select: COUNT` without item bytes:

```swift
let count = try await Order.query { ... }.count(using: client)
```

### Soto adapter

`DynamoQueriesSoto` provides a ``SotoDynamoClient`` that bridges the typed
inputs to [Soto](https://github.com/soto-project/soto)'s `DynamoDB` service
client:

```swift
import SotoDynamoDB
import DynamoQueries
import DynamoQueriesSoto

let awsClient = AWSClient(...)
let dynamoDB = DynamoDB(client: awsClient, region: .useast1)
let client: any DynamoClient = SotoDynamoClient(database: dynamoDB)
```

The adapter handles `UnprocessedKeys`/`UnprocessedItems` retry loops for
batch operations, translates Soto's `conditionalCheckFailedException` to
``ConditionalCheckFailed``, and translates `transactionCanceledException`
to ``TransactionCanceled``.

You can swap in a custom `DynamoClient` for tests — see
`Tests/DynamoQueriesTests/Helpers/RecordingDynamoClient.swift` for a
recording-mock implementation used in the test suite.

#### Codable encoding conventions

Whole-item reads and writes go through Soto's `DynamoDBEncoder` /
`DynamoDBDecoder`, applied directly to `DynamoDB.AttributeValue` — no JSON
intermediate, no `[String: Any]` boxing. Two project-specific conventions
are pinned at the adapter layer; the rest is stock Soto Codable.

  * **`Date` ↔ `.n(timeIntervalSince1970)`.** `dateEncodingStrategy` and
    `dateDecodingStrategy` are pinned to `.secondsSince1970` so the
    Codable path agrees with the `DynamoEncodable` extension on `Date`
    (see `DynamoQueries/Core/DynamoValue.swift`). Both write Unix-epoch
    seconds, which keeps DynamoDB indexes sortable and stays correct
    across timezones. If you need a different format, encode/decode the
    field as `Double` (or `String`) and convert at the boundary.

  * **Binary fields → `AWSBase64Data`, not `Data`.** Soto's coder only
    special-cases `AWSBase64Data` for the native `.b` (binary) attribute
    type. Plain `Data` falls through to `Data.encode(to:)`, which writes
    each byte as an integer in a list (`.l([.n("…"), …])`) — round-trip
    works, but the wire is roughly 4× the size of `.b` and not a real
    binary attribute. Declare binary fields as `AWSBase64Data`:

    ```swift
    import SotoDynamoDB

    @Table("TrailCards")
    struct TrailCard: Codable {
        @PartitionKey var cardTokenHash: String
        var ownerId: String
        var signature: AWSBase64Data?      // → .b on the wire
    }
    ```

    `AWSBase64Data.data(_:)` builds one from raw bytes; `.decoded()`
    returns the bytes back out. The Soto adapter conforms `AWSBase64Data`
    to ``DynamoEncodable`` and ``DynamoSizable`` so it works as a
    drop-in for `Data` in the manual query DSL too — `Filter { $0.signature.size == 0 }`
    compiles unchanged.

---

## Demos

This repo ships with example apps in the [`Examples`](./Examples) directory:

* [**TrailLog**](./Examples/TrailLog)
  <br> A small Lambda-style service that uses both libraries together — HTTP
  routing in front, DynamoDB-backed reads and writes behind. Models a
  hike-logging app: hikers record completed hikes against named trails,
  with elevation gain, distance, and a star rating per hike.

* [**RoutingDemo**](./Examples/RoutingDemo)
  <br> A focused example of `Routing` only: defining a `Routable` request,
  registering routes, composing middleware, and dispatching to handlers.

* [**DynamoQueriesDemo**](./Examples/DynamoQueriesDemo)
  <br> A focused example of `DynamoQueries` against `SotoDynamoClient`,
  walking through query, scan, put-if-not-exists, optimistic-concurrency
  update, batch write, and transact write.

Each demo is a runnable executable target declared in `Package.swift`.

## Documentation

DocC catalogs ship with each library:

  * `Sources/Routing/Documentation.docc`
  * `Sources/DynamoQueries/Documentation.docc`

Build them locally with:

```sh
swift package generate-documentation --target Routing
swift package generate-documentation --target DynamoQueries
```

Or open the package in Xcode and use **Product → Build Documentation**.

## Installation

Add LambdaKit as a Swift Package Manager dependency:

```swift
dependencies: [
    .package(url: "https://github.com/SongShift/lambda-kit.git", branch: "main")
]
```

…and pull in the products you need:

```swift
.product(name: "Routing", package: "lambda-kit"),
.product(name: "DynamoQueries", package: "lambda-kit"),
.product(name: "DynamoQueriesSoto", package: "lambda-kit"),
```

LambdaKit requires Swift 6.2+ and macOS 15+ (or AWS Lambda's Amazon Linux 2
runtime when deployed).
