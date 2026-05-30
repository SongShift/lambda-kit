//
//  Routes.swift
//
//  Wires the TrailLog HTTP surface up to its DynamoDB-backed handlers.
//  Uses the same routing shape as `RoutingDemo`: `HTTPRouterBuilder` against
//  the AWS Lambda transport types, with a logging middleware and a stub auth
//  middleware on every authenticated route.
//

import DynamoQueries
import Foundation
import HTTPTypes
import Logging
import Routing

// MARK: - Body payloads

struct CreateHikeBody: Decodable, Sendable {
    let trailName: String
    let distanceMiles: Double
    let elevationGainFeet: Int
    let rating: Int
    let notes: String?
    let tags: [String]?
}

struct ClaimHandleBody: Decodable, Sendable {
    let handle: String
}

// MARK: - Route registration

func registerRoutes(on builder: HTTPRouterBuilder, using db: any DynamoClient) {
    // Public route: health check, no auth.
    builder.get("/health") { _, _ in
        .json(["status": "ok"], statusCode: .ok)
    }

    // Authenticated routes: logging then auth.
    let authed = builder.withMiddleware {
        LoggingMiddleware()
        AuthMiddleware()
    }

    // GET /hikes/:id. Direct GetItem on the base table.
    authed.get("/hikes/:id") { context, _ in
        let id = try context.wrapped.pathParameters.require("id")
        let hike = try await Hike
            .get(partitionKey: id)
            .execute(using: db)
        guard let hike else {
            return .error(statusCode: .notFound, message: "No hike with id \(id)")
        }
        return .json(hike, statusCode: .ok)
    }

    // GET /hikers/:id/hikes?cursor=… Query the GSI, paginated.
    authed.get("/hikers/:id/hikes") { context, _ in
        let hikerID = try context.wrapped.pathParameters.require("id")
        let cursor = context.wrapped.queryParameters.get("cursor")
            .flatMap(PaginationToken.init(string:))

        let page = try await Hike.query { hike in
            Key { hike.hikerId == hikerID }
        }
        .usingIndex(Hike.Indexes.hikerCompletedAtIndex)
        .scanIndexForward(false)
        .limit(20)
        .startToken(cursor)
        .execute(using: db)

        struct Payload: Encodable, Sendable {
            let items: [Hike]
            let nextCursor: String?
        }
        return .json(
            Payload(items: page.items, nextCursor: page.nextToken?.stringValue),
            statusCode: .ok
        )
    }

    // POST /hikes. JSON body decode + put + counter bump. The hiker id
    // comes from the auth middleware's value, not the request URL.
    authed.post("/hikes", body: CreateHikeBody.self) { context, body, _ in
        let hikerID = context.value.value
        let hike = Hike(
            hikeId: UUID().uuidString,
            hikerId: hikerID,
            trailName: body.trailName,
            completedAt: Date().timeIntervalSince1970,
            distanceMiles: body.distanceMiles,
            elevationGainFeet: body.elevationGainFeet,
            rating: body.rating,
            notes: body.notes,
            tags: Set(body.tags ?? [])
        )
        let dayKey = ISO8601DateFormatter().string(from: Date())
            .prefix(10)
            .description

        try await TransactWriteInput {
            hike.put { hike in hike.hikeId.doesNotExist }
            HikeCount.update(
                partitionKey: hikerID,
                sortKey: dayKey,
                {
                    $0.count.add(1)
                }
            )
        }
        .execute(using: db)

        return .json(hike, statusCode: .created)
    }

    // POST /handles. Claim a handle (insert-if-not-exists).
    authed.post("/handles", body: ClaimHandleBody.self) { context, body, _ in
        let handle = HikerHandle(
            handleLower: body.handle.lowercased(),
            hikerId: context.value.value,
            reservedAt: Date().timeIntervalSince1970
        )
        do {
            try await handle
                .put { $0.handleLower.doesNotExist }
                .returnConflictingItem()
                .execute(using: db)
            return .json(handle, statusCode: .created)
        } catch let conflict as ConditionalCheckFailed<HikerHandle> {
            return .error(
                statusCode: .conflict,
                message: "Handle already claimed by \(conflict.priorItem?.hikerId ?? "another hiker")"
            )
        }
    }
}
