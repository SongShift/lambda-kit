//
//  RoutingDemo
//
//  A focused tour of the `Routing` library configured for AWS Lambda. The
//  demo registers a handful of trail-log routes against the lambda transport
//  types (`HTTPRequest`, `HTTPRouterBuilder`) and runs as a real
//  `LambdaRuntime`.
//

import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation
import Logging
import Routing

// MARK: - In-memory store

struct Hike: Sendable, Codable {
    let id: String
    let hikerId: String
    let trailName: String
    let distanceMiles: Double
    let elevationGainFeet: Int
    let rating: Int
}

actor HikeStore {
    private var hikes: [String: Hike] = [
        "mist-falls-001": Hike(
            id: "mist-falls-001",
            hikerId: "hiker-abc123",
            trailName: "Mist Falls",
            distanceMiles: 9.7,
            elevationGainFeet: 1500,
            rating: 5
        ),
    ]

    func get(id: String) -> Hike? { hikes[id] }
    func put(_ hike: Hike) { hikes[hike.id] = hike }
}

// MARK: - Build the router (cold-start cost only)

let store = HikeStore()
let routerBuilder = HTTPRouterBuilder()

// Public health check: no middleware.
routerBuilder.get("/health") { _, _ in
    .json(["status": "ok"], statusCode: .ok)
}

// Authenticated routes: every request runs through logging then auth.
let authed = routerBuilder.withMiddleware {
    LoggingMiddleware()
    AuthMiddleware()
}

// GET /hikes/:id. Read a hike by id. Auth happens first; handlers receive
// a `MiddlewareContext` exposing both the request (`.wrapped`) and the auth
// value (`.value`).
authed.get("/hikes/:id") { context, _ in
    let id = try context.wrapped.pathParameters.require("id")
    guard let hike = await store.get(id: id) else {
        return .error(statusCode: .notFound, message: "No hike with id \(id)")
    }
    return .json(hike, statusCode: .ok)
}

// POST /hikes. Record a new hike. The body overload JSON-decodes the
// request body before invoking the handler.
struct NewHike: Decodable, Sendable {
    let id: String
    let trailName: String
    let distanceMiles: Double
    let elevationGainFeet: Int
    let rating: Int
}

authed.post("/hikes", body: NewHike.self) { context, body, _ in
    let hiker = context.value
    let hike = Hike(
        id: body.id,
        hikerId: hiker.value,
        trailName: body.trailName,
        distanceMiles: body.distanceMiles,
        elevationGainFeet: body.elevationGainFeet,
        rating: body.rating
    )
    await store.put(hike)
    return .json(hike, statusCode: .created)
}

let router = routerBuilder.build()

// MARK: - Lambda runtime
//
// Build the runtime once at cold-start. The closure runs per invocation:
// wrap the AWS event in an `HTTPRequest`, dispatch it through the router,
// and translate the resulting `Response` back into an `APIGatewayV2Response`.

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
