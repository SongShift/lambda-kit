# TrailLog

A complete Lambda-shaped service that uses both LambdaKit libraries together:
HTTP routing in front, DynamoDB-backed reads and writes behind. The HTTP
surface is wired up exactly like [`RoutingDemo`](../RoutingDemo) —
`HTTPRouterBuilder` against the AWS Lambda transport types, dispatched by a
real `LambdaRuntime`. The schema models a hike-logging app: hikers record
completed hikes against named trails, with elevation gain, distance, and a
star rating per hike.

```sh
swift build --target TrailLogDemo
```

Running the executable directly only makes sense inside a Lambda environment
(or with the `swift-aws-lambda-runtime` local-server trait enabled).

## Layout

```
TrailLog/
├── README.md
└── Sources/
    ├── main.swift            — fake DynamoDB client + LambdaRuntime entry point
    ├── Models.swift          — @Table-decorated DynamoDB models
    ├── Routes.swift          — route registrations + handlers
    └── Middleware.swift      — logging + auth middleware
```

## What it demonstrates

  * Building an `HTTPRouter` once at cold-start and dispatching every Lambda
    invocation through it.
  * Composing a middleware chain (`LoggingMiddleware` then `AuthMiddleware`)
    via the `MiddlewareBuilder` result builder.
  * Registering routes both directly and through a middleware group, with and
    without JSON body decoding.
  * Modeling a DynamoDB table with `@Table`, `@PartitionKey`, `@SortKey`, and
    `@Index`.
  * Querying a base table and a GSI, putting items with a `where:` guard,
    and bumping a counter inside a `TransactWriteInput`.

## Auth in the demo

`AuthMiddleware` is a stub that always succeeds with a fixed `HikerID`. A
production version would verify a JWT (or similar) and short-circuit with
`401` on failure. The demo's write routes use this auth value as the
record's `hikerId`, so creating a hike via `POST /hikes` always attributes
it to `demo-hiker`.

## Real DynamoDB

The demo uses an in-memory `FakeDynamoClient` so it builds without AWS
credentials. To run against real DynamoDB, swap the client construction in
`main.swift` for a `SotoDynamoClient`:

```swift
import SotoDynamoDB
import DynamoQueriesSoto

let aws = AWSClient(httpClientProvider: .createNew)
let dynamoDB = DynamoDB(client: aws, region: .useast1)
let database: any DynamoClient = SotoDynamoClient(database: dynamoDB)
```
