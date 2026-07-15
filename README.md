# LambdaKit

LambdaKit is a toolkit for writing AWS Lambda services in Swift. Its libraries
ship independently: `Routing`, a typed request router for the API Gateway HTTP
and WebSocket event shapes; `DynamoQueries`, a typed DynamoDB query DSL; and
`APIGatewayV2Server`, a local development server that fronts your Lambda with
real HTTP. Pull in what you need.

## Installation

Add LambdaKit as a Swift Package Manager dependency:

```swift
dependencies: [
    .package(url: "https://github.com/SongShift/lambda-kit.git", branch: "main")
]
```

Then pull in the products you need:

```swift
.product(name: "Routing", package: "lambda-kit"),
.product(name: "DynamoQueries", package: "lambda-kit"),
.product(name: "DynamoQueriesSoto", package: "lambda-kit"),
.product(name: "APIGatewayV2Server", package: "lambda-kit"),
```

LambdaKit requires Swift 6.2+ and macOS 15+ (or AWS Lambda's Amazon Linux 2 / 2023
runtime when deployed).

## Routing

Build the router once at cold start, then dispatch every invocation through it:

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

Unmatched routes return `404`, unhandled errors return `500`, and typed
parameter errors translate to `400` automatically. Typed middleware chains,
JSON body decoding, and WebSocket routing are covered in the
[Routing documentation](Sources/Routing/Documentation.docc).

## DynamoQueries

The `@Table` macro lifts your table schema into the type system. Key
conditions, filters, and updates are written as Swift expressions against
typed columns and rendered into DynamoDB expression strings for you.

Declare a table, build a query, and stream the result pages:

```swift
import DynamoQueries
import DynamoQueriesSoto
import SotoDynamoDB

@Table("Hikes")
struct Hike: Codable, Sendable {
    @PartitionKey var hikerID: String
    @SortKey var hikeID: String
    var trailName: String
    var distanceMiles: Double
    var status: String
}

let dynamoDB = DynamoDB(client: AWSClient(...), region: .useast1)
let client: any DynamoClient = SotoDynamoClient(database: dynamoDB)

let query = Hike.query { hike in
    Key {
        hike.hikerID == "hiker-1"
        hike.hikeID.beginsWith("2026-")
    }
    Filter {
        hike.status != "abandoned"
        hike.distanceMiles > 5
    }
}
.limit(100)

for try await page in query.pages(using: client) {
    process(page.items)  // [Hike], one DynamoDB request per page
}
```

`execute(using:)` returns a single page with an opaque pagination cursor, and
`executeAll(using:)` collects every page. Writes, conditional checks, updates,
and batch and transactional operations are covered in the
[DynamoQueries documentation](Sources/DynamoQueries/Documentation.docc).

## APIGatewayV2Server

`APIGatewayV2Server` lets you run and exercise your Lambda locally with plain
HTTP — no API Gateway, SAM, or event JSON required. It starts an HTTP server
alongside the Lambda runtime's local server, translates each incoming request
into `APIGatewayV2Request` JSON, and POSTs it to the runtime's `/invoke`
endpoint, so `curl` and your app talk to the Lambda exactly as API Gateway
would.

The simplest way to use it is the `runWithAPIGateway()` extension on
`LambdaRuntime`, which runs both servers together:

```swift
import APIGatewayV2Server
import AWSLambdaRuntime

let runtime = LambdaRuntime { (event: APIGatewayV2Request, ctx: LambdaContext) in
    // your handler
}

#if DEBUG
try await runtime.runWithAPIGateway()
#else
try await runtime.run()
#endif
```

By default the HTTP server listens on port `3000` and the Lambda runtime on
port `7000`. Both are configurable through environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `LOCAL_HTTP_HOST` / `LOCAL_HTTP_PORT` | `127.0.0.1` / `3000` | Where the HTTP server listens |
| `LOCAL_LAMBDA_HOST` / `LOCAL_LAMBDA_PORT` | `127.0.0.1` / `7000` | Where the Lambda runtime's `/invoke` endpoint lives |
| `LOCAL_TLS_CERT_FILE` / `LOCAL_TLS_KEY_FILE` | unset | PEM certificate chain and private key; set both to serve HTTPS |

To simulate what API Gateway adds before your handler sees a request —
authentication headers, an authorizer context, a stage prefix — pass a
`RequestTransformer`, which gets to mutate each translated request before it
is forwarded:

```swift
struct AuthTransformer: RequestTransformer {
    func transform(_ request: inout MutableAPIGatewayV2Request) async {
        request.headers["x-user-id"] = "local-user"
    }
}

try await runtime.runWithAPIGateway(requestTransformer: AuthTransformer())
```

You can also construct and run an `APIGatewayV2Server` directly if you manage
the Lambda runtime process yourself.

## Examples

Runnable example apps live in the [`Examples`](./Examples) directory:

* [**TrailLog**](./Examples/TrailLog) uses both libraries together: HTTP
  routing in front, DynamoDB-backed reads and writes behind.
* [**RoutingDemo**](./Examples/RoutingDemo) covers `Routing` only: routes,
  middleware, and dispatch.
* [**DynamoQueriesDemo**](./Examples/DynamoQueriesDemo) walks through query,
  scan, conditional writes, batch write, and transact write.

## Documentation

DocC catalogs ship with each library. Build them locally with:

```sh
swift package generate-documentation --target Routing
swift package generate-documentation --target DynamoQueries
```

Or open the package in Xcode and use **Product > Build Documentation**.

## Contributing

Contributions are welcome. Please open an issue or submit a pull request.

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
