# Examples

This directory holds runnable demos for LambdaKit. Each example is an
executable target declared at the root of `Package.swift`, so you can build
or run any of them with `swift run <target>`.

  * [**TrailLog**](./TrailLog) — `swift run TrailLogDemo`
    <br> A complete Lambda-shaped service using both libraries together. Sets up
    an HTTP router, registers routes through middleware, and uses
    `DynamoQueries` for reads and writes. Models a hike-logging app:
    hikers record completed hikes against named trails, with elevation,
    distance, and rating per hike.

  * [**RoutingDemo**](./RoutingDemo) — `swift run RoutingDemo`
    <br> A focused demo of the `Routing` library wired up to the AWS Lambda
    transport types. Registers a small trail-log API on `HTTPRouterBuilder`,
    composes a `LoggingMiddleware` + `AuthMiddleware` chain, and dispatches
    synthetic `APIGatewayV2Request` events through the router so you can see
    the middleware flow without spinning up a Lambda.

  * [**DynamoQueriesDemo**](./DynamoQueriesDemo) — `swift run DynamoQueriesDemo`
    <br> A focused demo of the `DynamoQueries` library. Walks through the major
    operations against an in-memory `DynamoClient` mock: query, scan,
    put-if-not-exists, optimistic-concurrency update, batch write, and transact
    write.

The demos all run locally — none of them require AWS credentials. Where a
`DynamoClient` is needed, the focused demos use a recording mock; the
TrailLog demo wires up a `SotoDynamoClient` against a `localhost` DynamoDB
endpoint (point at [DynamoDB Local] to actually exercise it).

[DynamoDB Local]: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html
