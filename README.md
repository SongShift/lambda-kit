# LambdaKit

LambdaKit is a toolkit for writing AWS Lambda services in Swift. It has two
libraries that ship independently: `Routing`, a typed request router for the
API Gateway HTTP and WebSocket event shapes, and `DynamoQueries`, a typed
DynamoDB query DSL. Pull in one or both.

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
```

LambdaKit requires Swift 6.2+ and macOS 15+ (or AWS Lambda's Amazon Linux 2
runtime when deployed).
