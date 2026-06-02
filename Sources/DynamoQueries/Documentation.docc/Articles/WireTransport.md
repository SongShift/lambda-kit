# Wire transport

How requests get to DynamoDB — and how to swap that out for tests.

## Overview

``DynamoClient`` is the transport-level interface every adapter implements.
The protocol is intentionally non-chainable: chaining lives on the typed
inputs (``QueryInput``, ``ScanInput``, etc.); the client's job is just to
ferry a fully-built request to DynamoDB and decode the response.

Every method takes a `logger` the adapter forwards to its transport. Call sites
rarely pass one directly: the `*Input.execute(using:)` family defaults to
``Logger/dynamoQueriesDisabled``, and the `execute(using:logger:)` overload
threads a real per-request logger (e.g. a Lambda's `context.logger`) through to
DynamoDB.

```swift
public protocol DynamoClient: Sendable {
    func execute<Model: DynamoModel>(_ input: QueryInput<Model>, logger: Logger) async throws -> QueryPage<Model>
    func getItem<Model: DynamoModel>(_ input: GetItemInput<Model>, logger: Logger) async throws -> Model?
    func putItem<Model: DynamoModel>(_ input: PutItemInput<Model>, logger: Logger) async throws
    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>, logger: Logger) async throws
    // ... and so on for delete, scan, count, batchGet, batchWrite, transactWrite.
}
```

```swift
// Logging disabled (the default):
let page = try await Model.query { Key { $0.id == id } }.execute(using: client)

// Opt in to per-request logging:
let page = try await Model.query { Key { $0.id == id } }
    .execute(using: client, logger: context.logger)
```

## SotoDynamoClient

The companion `DynamoQueriesSoto` product provides `SotoDynamoClient`, which
adapts every operation to [Soto](https://github.com/soto-project/soto)'s
`DynamoDB` service client:

```swift
import SotoDynamoDB
import DynamoQueries
import DynamoQueriesSoto

let aws = AWSClient(httpClientProvider: .createNew)
let dynamoDB = DynamoDB(client: aws, region: .useast1)
let client: any DynamoClient = SotoDynamoClient(database: dynamoDB)
```

The adapter handles a few concerns the protocol leaves to the implementation:

  * `UnprocessedKeys` / `UnprocessedItems` retry loops for batch operations.
  * Translating Soto's `conditionalCheckFailedException` into a typed
    ``ConditionalCheckFailed``, decoding the prior item out of the
    extended-error payload when the request asked for it.
  * Translating `transactionCanceledException` into ``TransactionCanceled``
    with one ``TransactionCanceled/Cancellation`` per leg.
  * Placeholdering projection attributes (DynamoDB rejects unescaped reserved
    words like `name` / `status` / `count` in projection expressions).

## Custom clients

For tests, you'll typically want a recording client that captures every
request the DSL produces and hands back canned responses. The test suite's
`RecordingDynamoClient` is a working example: it stores each input keyed
by model type so individual tests can assert on specific operations.

A skeleton looks like this:

```swift
actor MockDynamoClient: DynamoClient {
    var queries: [Any] = []

    func execute<Model: DynamoModel>(_ input: QueryInput<Model>, logger: Logger) async throws -> QueryPage<Model> {
        queries.append(input)
        return QueryPage(items: [], nextToken: nil)
    }
    // ... implement the remaining methods to fit the operations under test.
}
```

If you're building a custom adapter for another DynamoDB SDK (or DynamoDB
Local over a different transport), the pattern is the same as
`SotoDynamoClient`: convert each input to the SDK's request shape, fire the
request, decode the response back into the typed return type.
