import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// Each test below pairs a hand-written Soto request — anonymized from a real
// FusionBackend call site — with the equivalent built through the
// DynamoQueries DSL. The two are then compared after substituting placeholders
// into the expression strings; see `Helpers/Equivalence.swift` for how that
// works.
//
// The Soto reference fixtures use the same parenthesization that the
// `ExpressionCompiler` emits (`(left) AND (right)`), so the resolved
// expressions match byte-for-byte.

@Suite("Query equivalence")
struct QueryEquivalenceTests {

    @Test("Query: partition-key equality only")
    func queryPartitionKeyOnly() async throws {
        let client = RecordingDynamoClient()
        _ = try await HikingSession.query { column in
            Key {
                column.hikerId == "hiker-123"
            }
        }
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: HikingSession.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [":hikerId": .s("hiker-123")],
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailHikingSessions"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: pk = AND begins_with(sk, ...)")
    func queryBeginsWithSortKey() async throws {
        let client = RecordingDynamoClient()
        _ = try await Hike.query { column in
            Key {
                column.hikeId == "hike-1"
                column.hikerSeasonGrade.beginsWith("hiker-9")
            }
        }
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: Hike.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikeId": .s("hike-1"),
                ":hikerId": .s("hiker-9"),
            ],
            keyConditionExpression:
                "(hikeId = :hikeId) AND (begins_with(hikerSeasonGrade, :hikerId))",
            tableName: "TrailHikes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: filter expression on top of a key condition (descending GSI)")
    func queryWithFilterOnKey() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key {
                column.hikerId == "hiker-123"
            }
            Filter {
                column.isFavorite.doesNotExist || column.isFavorite != true
                column.isPrivate.doesNotExist || column.isPrivate != true
            }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .scanIndexForward(false)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-123"),
                ":trueValue": .bool(true),
            ],
            filterExpression:
                "((attribute_not_exists(isFavorite)) OR (isFavorite <> :trueValue)) AND ((attribute_not_exists(isPrivate)) OR (isPrivate <> :trueValue))",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            scanIndexForward: false,
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: GSI w/ pk and numeric sort-key equality")
    func queryGSIWithNumericSortKeyEquality() async throws {
        let client = RecordingDynamoClient()
        _ = try await MapImport.query { column in
            Key {
                column.hikerId == "hiker-123"
                column.isArchived == 0
            }
        }
        .usingIndex(MapImport.Indexes.hikerArchivedCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: MapImport.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-123"),
                ":zero": .n("0"),
            ],
            indexName: "hikerArchivedCreatedAtIndex",
            keyConditionExpression: "(hikerId = :hikerId) AND (isArchived = :zero)",
            tableName: "TrailMapImports"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: four-clause AND key condition with limit")
    func queryFourClauseKeyConditionWithLimit() async throws {
        let client = RecordingDynamoClient()
        _ = try await ShareLink.query { column in
            Key {
                column.creatorId == "hiker-1"
                column.isArchived == 0
                column.isPrivate == 0
                column.isPinned == 0
            }
        }
        .usingIndex(ShareLink.Indexes.creatorPublicProfileIndex)
        .limit(25)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: ShareLink.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":creatorId": .s("hiker-1"),
                ":zero": .n("0"),
            ],
            indexName: "creatorPublicProfileIndex",
            keyConditionExpression:
                "(((creatorId = :creatorId) AND (isArchived = :zero)) AND (isPrivate = :zero)) AND (isPinned = :zero)",
            limit: 25,
            tableName: "TrailShareLinks"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: contains() on a Set<String> attribute")
    func filterContainsOnStringSet() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.tags.contains("summit") }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":tag": .s("summit"),
            ],
            filterExpression: "contains(tags, :tag)",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: Date attribute composes with comparison operators")
    func filterOnDateAttribute() async throws {
        let client = RecordingDynamoClient()
        let cutoff = Date(timeIntervalSince1970: 1735776000)
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.lastSeen > cutoff }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":cutoff": .n("1735776000.0"),
            ],
            filterExpression: "lastSeen > :cutoff",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: size(stringAttr) > N")
    func filterSizeOnString() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.nameLower.size > 32 }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":maxLen": .n("32"),
            ],
            filterExpression: "size(nameLower) > :maxLen",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: size(set) >= N")
    func filterSizeOnSet() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.tags.size >= 3 }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":minTags": .n("3"),
            ],
            filterExpression: "size(tags) >= :minTags",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: size(list).between(_:and:)")
    func filterSizeBetween() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.aliases.size.between(1, and: 10) }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":lo": .n("1"),
                ":hi": .n("10"),
            ],
            filterExpression: "size(aliases) BETWEEN :lo AND :hi",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: size(optionalBinaryAttr) == 0")
    func filterSizeOnOptionalBinary() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailCard.query { column in
            Key { column.cardTokenHash == "hash-9f" }
            Filter { column.signature.size == 0 }
        }
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailCard.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hash": .s("hash-9f"),
                ":zero": .n("0"),
            ],
            filterExpression: "size(signature) = :zero",
            keyConditionExpression: "cardTokenHash = :hash",
            tableName: "TrailCards"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Filter: contains() on a [String] (list) attribute")
    func filterContainsOnStringList() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.aliases.contains("Mist Falls") }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":alias": .s("Mist Falls"),
            ],
            filterExpression: "contains(aliases, :alias)",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: consistentRead modifier propagates to Soto")
    func queryConsistentRead() async throws {
        let client = RecordingDynamoClient()
        _ = try await HikingSession.query { column in
            Key {
                column.hikerId == "hiker-123"
            }
        }
        .consistentRead()
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: HikingSession.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            consistentRead: true,
            expressionAttributeValues: [":hikerId": .s("hiker-123")],
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailHikingSessions"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: top-level if-Filter is included when condition is true")
    func queryTopLevelIfFilterIncluded() async throws {
        let client = RecordingDynamoClient()
        let includeFavoritesOnly = true
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            if includeFavoritesOnly {
                Filter { column.isFavorite == true }
            }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":trueValue": .bool(true),
            ],
            filterExpression: "isFavorite = :trueValue",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: top-level if-Filter is omitted when condition is false")
    func queryTopLevelIfFilterOmitted() async throws {
        let client = RecordingDynamoClient()
        let includeFavoritesOnly = false
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            if includeFavoritesOnly {
                Filter { column.isFavorite == true }
            }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [":hikerId": .s("hiker-1")],
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: top-level if/else picks the correct Filter branch")
    func queryTopLevelIfElseFilter() async throws {
        let client = RecordingDynamoClient()
        let publicOnly = false
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            if publicOnly {
                Filter { column.isPrivate == false }
            } else {
                Filter { column.isFavorite == true }
            }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":trueValue": .bool(true),
            ],
            filterExpression: "isFavorite = :trueValue",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - GetItem

@Suite("GetItem equivalence")
struct GetItemEquivalenceTests {

    @Test("GetItem: partition key only (string pk)")
    func getItemPartitionKeyOnly() async throws {
        let client = RecordingDynamoClient()
        _ = try await PhotoScan.get(partitionKey: "scan-abc").execute(using: client)
        let captured = try #require(await client.lastGetInput(for: PhotoScan.self))
        let dslSoto = captured.toSotoGetItemInput()

        let reference = DynamoDB.GetItemInput(
            key: ["id": .s("scan-abc")],
            tableName: "TrailPhotoScans"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("GetItem: partition key + numeric sort key")
    func getItemCompositeKey() async throws {
        let client = RecordingDynamoClient()
        _ = try await HikingSession.get(partitionKey: "hiker-123", sortKey: 2).execute(using: client)
        let captured = try #require(await client.lastGetInput(for: HikingSession.self))
        let dslSoto = captured.toSotoGetItemInput()

        let reference = DynamoDB.GetItemInput(
            key: [
                "hikerId": .s("hiker-123"),
                "sessionNumber": .n("2"),
            ],
            tableName: "TrailHikingSessions"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("GetItem: consistentRead modifier propagates to Soto")
    func getItemConsistentRead() async throws {
        let client = RecordingDynamoClient()
        _ = try await PhotoScan.get(partitionKey: "scan-abc")
            .consistentRead()
            .execute(using: client)
        let captured = try #require(await client.lastGetInput(for: PhotoScan.self))
        let dslSoto = captured.toSotoGetItemInput()

        let reference = DynamoDB.GetItemInput(
            consistentRead: true,
            key: ["id": .s("scan-abc")],
            tableName: "TrailPhotoScans"
        )
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - PutItem

@Suite("PutItem equivalence")
struct PutItemEquivalenceTests {

    @Test("PutItem: insert-only condition (attribute_not_exists)")
    func putItemInsertOnly() async throws {
        let client = RecordingDynamoClient()
        let chart = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1735776000.0
        )
        try await chart.put { column in
            column.cardTokenHash.doesNotExist
        }
        .execute(using: client)
        let captured = try #require(await client.lastPutInput(for: TrailCard.self))
        let dslSoto = try captured.toSotoPutItemInput()

        let reference = DynamoDB.PutItemInput(
            conditionExpression: "attribute_not_exists(cardTokenHash)",
            item: [:],
            tableName: "TrailCards"
        )
        expectEquivalentMetadata(dslSoto, reference)
    }

    @Test("PutItem: optimistic-concurrency condition on non-key attribute")
    func putItemOptimisticConcurrency() async throws {
        let client = RecordingDynamoClient()
        let score = DifficultyScore(id: "id-77", score: 0.83, lastClimbedAt: 1735862400.0)
        try await score.put { column in
            column.lastClimbedAt == 1735776000.0
        }
        .execute(using: client)
        let captured = try #require(await client.lastPutInput(for: DifficultyScore.self))
        let dslSoto = try captured.toSotoPutItemInput()

        let reference = DynamoDB.PutItemInput(
            conditionExpression: "lastClimbedAt = :expectedLastClimbedAt",
            expressionAttributeValues: [":expectedLastClimbedAt": .n("1735776000.0")],
            item: [:],
            tableName: "TrailDifficultyScores"
        )
        expectEquivalentMetadata(dslSoto, reference)
    }
}

// MARK: - UpdateItem

@Suite("UpdateItem equivalence")
struct UpdateItemEquivalenceTests {

    // The original FusionBackend code expresses this counter as
    //   SET #count = if_not_exists(#count, :zero) + :one
    // which DynamoQueries doesn't model (it has no arithmetic SET). Its
    // canonical equivalent is `add(1)`, which compiles to `ADD count :one` —
    // DynamoDB initializes a missing numeric attribute to 0 before applying
    // the delta, so the two updates have identical observed behavior. The
    // reference here is written in the `ADD` form to match.
    @Test("UpdateItem: atomic counter via ADD")
    func updateItemAtomicCounter() async throws {
        let client = RecordingDynamoClient()
        try await HikeEvent.update(
            partitionKey: "hiker-123",
            sortKey: "summited"
        ) { column in
            column.hikeCount.add(1)
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: HikeEvent.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":one": .n("1")],
            key: [
                "hikerId": .s("hiker-123"),
                "eventKey": .s("summited"),
            ],
            tableName: "TrailHikeEvents",
            updateExpression: "ADD hikeCount :one"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: list append uses list_append(name, :items)")
    func updateItemListAppend() async throws {
        let client = RecordingDynamoClient()
        try await TrailRoute.update(partitionKey: "route-1") { column in
            column.aliases.append(["Mist Falls", "Lake Loop"])
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: TrailRoute.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [
                ":items": .l([.s("Mist Falls"), .s("Lake Loop")]),
            ],
            key: ["routeId": .s("route-1")],
            tableName: "TrailRoutes",
            updateExpression: "SET aliases = list_append(aliases, :items)"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: list prepend swaps the list_append argument order")
    func updateItemListPrepend() async throws {
        let client = RecordingDynamoClient()
        try await TrailRoute.update(partitionKey: "route-1") { column in
            column.aliases.prepend(["alpha"])
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: TrailRoute.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":items": .l([.s("alpha")])],
            key: ["routeId": .s("route-1")],
            tableName: "TrailRoutes",
            updateExpression: "SET aliases = list_append(:items, aliases)"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: addToSet emits ADD with the elements")
    func updateItemAddToSet() async throws {
        let client = RecordingDynamoClient()
        try await TrailRoute.update(partitionKey: "route-1") { column in
            column.tags.addToSet(["new-tag"])
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: TrailRoute.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":new": .ss(["new-tag"])],
            key: ["routeId": .s("route-1")],
            tableName: "TrailRoutes",
            updateExpression: "ADD tags :new"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: removeFromSet emits DELETE with the elements")
    func updateItemRemoveFromSet() async throws {
        let client = RecordingDynamoClient()
        try await TrailRoute.update(partitionKey: "route-1") { column in
            column.tags.removeFromSet(["stale"])
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: TrailRoute.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":stale": .ss(["stale"])],
            key: ["routeId": .s("route-1")],
            tableName: "TrailRoutes",
            updateExpression: "DELETE tags :stale"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: SET a Set<String> attribute")
    func updateItemSetStringSet() async throws {
        let client = RecordingDynamoClient()
        try await TrailRoute.update(partitionKey: "route-1") { column in
            column.tags.set(to: Set<String>(["summit", "alpine"]))
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: TrailRoute.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":tags": .ss(["summit", "alpine"])],
            key: ["routeId": .s("route-1")],
            tableName: "TrailRoutes",
            updateExpression: "SET tags = :tags"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("UpdateItem: SET multiple attrs with three-clause condition")
    func updateItemWithComplexCondition() async throws {
        let client = RecordingDynamoClient()
        try await PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
            column.updatedAt.set(to: 1735776000.0)
            column.reason.set(to: "manual override")
        } where: { column in
            column.id.exists
            column.status != "processing"
            column.status != "completed"
        }
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: PhotoScan.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        let reference = DynamoDB.UpdateItemInput(
            conditionExpression:
                "((attribute_exists(id)) AND (status <> :processing)) AND (status <> :completed)",
            expressionAttributeValues: [
                ":processing": .s("processing"),
                ":completed": .s("completed"),
                ":updatedAt": .n("1735776000.0"),
                ":reason": .s("manual override"),
            ],
            key: ["id": .s("scan-abc")],
            tableName: "TrailPhotoScans",
            updateExpression:
                "SET status = :processing, updatedAt = :updatedAt, reason = :reason"
        )
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - DeleteItem

@Suite("DeleteItem equivalence")
struct DeleteItemEquivalenceTests {

    @Test("DeleteItem: condition on a non-key attribute")
    func deleteItemWithCondition() async throws {
        let client = RecordingDynamoClient()
        try await HikerHandle.delete(partitionKey: "alice") { column in
            column.hikerId == "hiker-123"
        }
        .execute(using: client)
        let captured = try #require(await client.lastDeleteInput(for: HikerHandle.self))
        let dslSoto = captured.toSotoDeleteItemInput()

        let reference = DynamoDB.DeleteItemInput(
            conditionExpression: "hikerId = :expectedHikerId",
            expressionAttributeValues: [":expectedHikerId": .s("hiker-123")],
            key: ["handleLower": .s("alice")],
            tableName: "TrailHikerHandles"
        )
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - Scan

@Suite("Scan equivalence")
struct ScanEquivalenceTests {

    @Test("Scan: no filter, no exclusiveStartKey")
    func scanWithNoFilter() async throws {
        let client = RecordingDynamoClient()
        _ = try await PendingHikeBatch.scan().execute(using: client)
        let captured = try #require(await client.lastScanInput(for: PendingHikeBatch.self))
        let dslSoto = captured.toSotoScanInput()

        let reference = DynamoDB.ScanInput(tableName: "TrailPendingHikeBatches")
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - Projections

@Suite("Projection expressions")
struct ProjectionTests {

    @Test("Query: .project(...) emits a placeholdered projectionExpression")
    func queryAttributesProjection() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .project(TrailRoute.$routeId, TrailRoute.$nameLower)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeNames: [
                "#p0": "routeId",
                "#p1": "nameLower",
            ],
            expressionAttributeValues: [":hikerId": .s("hiker-1")],
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            projectionExpression: "#p0, #p1",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }

    // `status` is a reserved DynamoDB word — projecting it as a raw name
    // would be rejected by the service, so the adapter must emit it as a
    // placeholder. This test pins that behavior.
    @Test("GetItem: projection placeholders a reserved-word attribute (status)")
    func getItemProjectionWithReservedWord() async throws {
        let client = RecordingDynamoClient()
        _ = try await PhotoScan.get(partitionKey: "scan-abc")
            .project(PhotoScan.$id, PhotoScan.$status)
            .execute(using: client)
        let captured = try #require(await client.lastGetInput(for: PhotoScan.self))
        let dslSoto = captured.toSotoGetItemInput()

        let reference = DynamoDB.GetItemInput(
            expressionAttributeNames: ["#p0": "id", "#p1": "status"],
            key: ["id": .s("scan-abc")],
            projectionExpression: "#p0, #p1",
            tableName: "TrailPhotoScans"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Scan: .project([_]) array overload")
    func scanAttributesArrayOverload() async throws {
        let client = RecordingDynamoClient()
        let attrs: [any AttributeReference] = [
            PendingHikeBatch.$batchId,
            PendingHikeBatch.$attempts,
        ]
        _ = try await PendingHikeBatch.scan()
            .project(attrs)
            .execute(using: client)
        let captured = try #require(await client.lastScanInput(for: PendingHikeBatch.self))
        let dslSoto = captured.toSotoScanInput()

        let reference = DynamoDB.ScanInput(
            expressionAttributeNames: ["#p0": "batchId", "#p1": "attempts"],
            projectionExpression: "#p0, #p1",
            tableName: "TrailPendingHikeBatches"
        )
        expectEquivalent(dslSoto, reference)
    }

    @Test("Query: projection placeholders coexist with filter placeholders without collision")
    func queryProjectionAlongsideFilter() async throws {
        let client = RecordingDynamoClient()
        _ = try await TrailRoute.query { column in
            Key { column.hikerId == "hiker-1" }
            Filter { column.tags.contains("summit") }
        }
        .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
        .project(TrailRoute.$routeId, TrailRoute.$nameLower)
        .execute(using: client)
        let dslSoto = try #require(await client.lastQueryInput(for: TrailRoute.self)).toSotoQueryInput()

        let reference = DynamoDB.QueryInput(
            expressionAttributeNames: [
                "#p0": "routeId",
                "#p1": "nameLower",
            ],
            expressionAttributeValues: [
                ":hikerId": .s("hiker-1"),
                ":tag": .s("summit"),
            ],
            filterExpression: "contains(tags, :tag)",
            indexName: "hikerCreatedAtIndex",
            keyConditionExpression: "hikerId = :hikerId",
            projectionExpression: "#p0, #p1",
            tableName: "TrailRoutes"
        )
        expectEquivalent(dslSoto, reference)
    }
}

// MARK: - Batch get

@Suite("Batch get")
struct BatchGetTests {

    @Test("BatchGet: partition-key-only builder collapses keys into the right shape")
    func batchGetPartitionKeyOnly() async throws {
        let client = RecordingDynamoClient()
        let stub = [
            PhotoScan(id: "scan-1", status: "completed", updatedAt: 0),
            PhotoScan(id: "scan-3", status: "processing", updatedAt: 1),
        ]
        await client.seedBatchGetResults(stub, for: PhotoScan.self)

        let items = try await PhotoScan.batchGet(
            partitionKeys: ["scan-1", "scan-2", "scan-3"]
        )
        .execute(using: client)

        #expect(items.count == 2)
        let captured = try #require(await client.lastBatchGetInput(for: PhotoScan.self))
        #expect(captured.tableName == "TrailPhotoScans")
        #expect(captured.keys.count == 3)
        #expect(captured.keys.allSatisfy { Set($0.keys) == ["id"] })
    }

    @Test("BatchGet: composite-key builder includes partition + sort in each key map")
    func batchGetCompositeKey() async throws {
        let client = RecordingDynamoClient()

        _ = try await HikingSession.batchGet(
            keys: [
                (partitionKey: "hiker-a", sortKey: 1),
                (partitionKey: "hiker-a", sortKey: 2),
            ]
        )
        .execute(using: client)

        let captured = try #require(await client.lastBatchGetInput(for: HikingSession.self))
        #expect(captured.keys.count == 2)
        for key in captured.keys {
            #expect(Set(key.keys) == ["hikerId", "sessionNumber"])
        }
    }

    @Test("BatchGet: .consistentRead() and .project() chain")
    func batchGetWithModifiers() async throws {
        let client = RecordingDynamoClient()
        _ = try await PhotoScan.batchGet(partitionKeys: ["scan-1"])
            .consistentRead()
            .project(PhotoScan.$id, PhotoScan.$status)
            .execute(using: client)
        let captured = try #require(await client.lastBatchGetInput(for: PhotoScan.self))
        #expect(captured.consistentRead == true)
        #expect(captured.projectionAttributes == ["id", "status"])
    }
}

// MARK: - Transact write

@Suite("Transact write")
struct TransactWriteTests {

    @Test("Mixes Put / Update / Delete / ConditionCheck across tables")
    func transactWriteMixedKinds() async throws {
        let client = RecordingDynamoClient()
        let chart = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1735776000.0
        )
        try await TransactWriteInput {
            chart.put { column in column.cardTokenHash.doesNotExist }
            try PhotoScan.update(partitionKey: "scan-abc") { column in
                column.status.set(to: "processing")
            } where: { column in
                column.status != "processing"
            }
            try HikerHandle.delete(partitionKey: "alice") { column in
                column.hikerId == "hiker-OTHER"
            }
            try DifficultyScore.conditionCheck(partitionKey: "score-1") { column in
                column.lastClimbedAt == 1735776000.0
            }
        }
        .execute(using: client)

        let captured = try #require(await client.lastTransactWriteItems)
        #expect(captured.count == 4)

        // Each leg lands on its declared table with the right kind.
        let kinds = captured.map { item in
            (item.tableName, kindLabel(item.kind))
        }
        #expect(kinds[0] == ("TrailCards", "put"))
        #expect(kinds[1] == ("TrailPhotoScans", "update"))
        #expect(kinds[2] == ("TrailHikerHandles", "delete"))
        #expect(kinds[3] == ("TrailDifficultyScores", "conditionCheck"))
    }

    @Test("execute() rethrows TransactionCanceled with per-leg cancellations")
    func transactWriteRethrowsCanceled() async throws {
        let client = RecordingDynamoClient()
        let priorScan = PhotoScan(id: "scan-abc", status: "completed", updatedAt: 0)
        let priorRaw = ["id": DynamoValue.string("scan-abc"), "status": .string("completed")]
        let canceled = TransactionCanceled(cancellations: [
            .init(index: 0, code: "None", message: nil, priorRawItem: nil),
            .init(index: 1, code: "ConditionalCheckFailed", message: "leg 1 failed", priorRawItem: priorRaw),
        ])
        await client.throwOnTransactWrite(canceled)

        let chart = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1735776000.0
        )
        do {
            try await TransactWriteInput {
                chart.put { column in column.cardTokenHash.doesNotExist }
                try PhotoScan.update(partitionKey: "scan-abc") { column in
                    column.status.set(to: "processing")
                } where: { column in
                    column.status != "processing"
                }
            }
            .execute(using: client)
            Issue.record("expected TransactionCanceled to throw")
        } catch let cancellation as TransactionCanceled {
            #expect(cancellation.cancellations.count == 2)
            #expect(cancellation.cancellations[0].code == "None")
            #expect(cancellation.cancellations[1].code == "ConditionalCheckFailed")
            #expect(cancellation.cancellations[1].priorRawItem?["id"] == .string("scan-abc"))
        }
        // suppress unused var warning
        _ = priorScan
    }

    @Test("ConditionCheck builder compiles its expression and key")
    func conditionCheckBuilder() async throws {
        let item = try DifficultyScore.conditionCheck(partitionKey: "score-1") { column in
            column.lastClimbedAt == 1735776000.0
        }
        guard case .conditionCheck(let key, let condition) = item.kind else {
            Issue.record("expected .conditionCheck")
            return
        }
        #expect(key == ["id": .string("score-1")])
        // Resolved expression matches the hand-written form after placeholder
        // substitution.
        let resolved = resolve(
            expression: condition.expression,
            names: condition.attributeNames,
            values: condition.attributeValues.mapValues { $0.toSotoAttributeValue() }
        )
        #expect(resolved?.expanded == "lastClimbedAt = N(1735776000.0)")
    }
}

private func kindLabel(_ kind: TransactWriteItem.Kind) -> String {
    switch kind {
    case .put: return "put"
    case .update: return "update"
    case .delete: return "delete"
    case .conditionCheck: return "conditionCheck"
    }
}

// MARK: - Batch write

@Suite("Batch write")
struct BatchWriteTests {

    @Test("Chained .put / .delete builds matching put + delete arrays")
    func batchWriteChainedPutDelete() async throws {
        let client = RecordingDynamoClient()
        try await PhotoScan.batchWrite()
            .put(PhotoScan(id: "scan-1", status: "completed", updatedAt: 0))
            .put(PhotoScan(id: "scan-2", status: "completed", updatedAt: 0))
            .delete(partitionKey: "scan-3")
            .execute(using: client)

        let captured = try #require(await client.lastBatchWriteInput(for: PhotoScan.self))
        #expect(captured.tableName == "TrailPhotoScans")
        #expect(captured.putItems.count == 2)
        #expect(captured.deleteKeys.count == 1)
        #expect(captured.deleteKeys[0] == ["id": .string("scan-3")])
    }

    @Test("Composite-key delete includes both pk and sk")
    func batchWriteCompositeDelete() async throws {
        let client = RecordingDynamoClient()
        try await HikingSession.batchWrite()
            .delete(partitionKey: "hiker-a", sortKey: 1)
            .delete(partitionKey: "hiker-a", sortKey: 2)
            .execute(using: client)

        let captured = try #require(await client.lastBatchWriteInput(for: HikingSession.self))
        #expect(captured.deleteKeys.count == 2)
        for key in captured.deleteKeys {
            #expect(Set(key.keys) == ["hikerId", "sessionNumber"])
        }
    }

    @Test("Composite-key delete on a partition-only table throws")
    func batchWriteWrongArityThrows() async throws {
        var threw = false
        do {
            _ = try PhotoScan.batchWrite().delete(partitionKey: "scan-1", sortKey: 1)
        } catch PrimaryKeyError.unexpectedSortKey {
            threw = true
        }
        #expect(threw)
    }
}

// MARK: - Update return values

@Suite("UpdateItem return values")
struct UpdateReturnValuesTests {

    @Test("returnNewValues() flips ReturnValues = ALL_NEW on the wire")
    func returnNewValuesAllNew() async throws {
        let returning = try PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
        .returnNewValues()
        let soto = returning.toSotoUpdateItemInput()
        #expect(soto.returnValues == .allNew)
    }

    @Test("returnOldValues() flips ReturnValues = ALL_OLD on the wire")
    func returnOldValuesAllOld() async throws {
        let returning = try PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
        .returnOldValues()
        let soto = returning.toSotoUpdateItemInput()
        #expect(soto.returnValues == .allOld)
    }

    @Test("returnUpdatedNewValues() flips ReturnValues = UPDATED_NEW")
    func returnUpdatedNewValues() async throws {
        let returning = try PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
        .returnUpdatedNewValues()
        let soto = returning.toSotoUpdateItemInput()
        #expect(soto.returnValues == .updatedNew)
    }

    @Test("Returning execute() decodes the seeded item")
    func returningExecuteReturnsItem() async throws {
        let client = RecordingDynamoClient()
        let updated = PhotoScan(
            id: "scan-abc",
            status: "processing",
            updatedAt: 1735776000.0,
            reason: nil
        )
        await client.seedUpdateReturnItem(updated, for: PhotoScan.self)

        let returned = try await PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
        .returnNewValues()
        .execute(using: client)

        #expect(returned?.id == "scan-abc")
        #expect(returned?.status == "processing")
    }
}

// MARK: - Count queries

@Suite("Count queries")
struct CountTests {

    @Test("Query: count(using:) sums across paginated count responses")
    func queryCountSumsAcrossPages() async throws {
        let client = RecordingDynamoClient()
        let token1 = PaginationToken(key: ["hikerId": .string("hiker-1")])
        let token2 = PaginationToken(key: ["hikerId": .string("hiker-2")])
        await client.seedQueryCountPages(
            [
                CountPage(count: 100, scannedCount: 100, nextToken: token1),
                CountPage(count: 50, scannedCount: 50, nextToken: token2),
                CountPage(count: 7, scannedCount: 7, nextToken: nil),
            ],
            for: HikingSession.self
        )

        let total = try await HikingSession.query { column in
            Key { column.hikerId == "hiker-x" }
        }
        .count(using: client)

        #expect(total == 157)
        let recorded = await client.recordedCountQueryInputs(for: HikingSession.self)
        #expect(recorded.count == 3)
        #expect(recorded.allSatisfy { $0.selectCountOnly })
        #expect(recorded[0].exclusiveStartKey == nil)
        #expect(recorded[1].exclusiveStartKey == token1.key)
        #expect(recorded[2].exclusiveStartKey == token2.key)
    }

    @Test("Scan: count(using:) sums across paginated count responses")
    func scanCountSumsAcrossPages() async throws {
        let client = RecordingDynamoClient()
        let token = PaginationToken(key: ["batchId": .string("batch-mid")])
        await client.seedScanCountPages(
            [
                CountPage(count: 12, scannedCount: 50, nextToken: token),
                CountPage(count: 3, scannedCount: 10, nextToken: nil),
            ],
            for: PendingHikeBatch.self
        )

        let total = try await PendingHikeBatch.scan().count(using: client)

        #expect(total == 15)
        let recorded = await client.recordedCountScanInputs(for: PendingHikeBatch.self)
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.selectCountOnly })
    }

    @Test("Query: count flag flows through to Soto's Select: COUNT")
    func querySelectCountReachesSoto() async throws {
        var input = HikingSession.query { column in
            Key { column.hikerId == "hiker-1" }
        }
        input.selectCountOnly = true
        let soto = input.toSotoQueryInput()
        #expect(soto.select == .count)
    }
}

// MARK: - Conditional-check failure recovery

@Suite("Conditional-check failure recovery")
struct ConditionalCheckTests {

    @Test("PutItem: .returnConflictingItem() flips ALL_OLD on the wire")
    func putReturnConflictingItemFlipsAllOld() async throws {
        let client = RecordingDynamoClient()
        let chart = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1735776000.0
        )
        try await chart.put { column in column.cardTokenHash.doesNotExist }
            .returnConflictingItem()
            .execute(using: client)
        let captured = try #require(await client.lastPutInput(for: TrailCard.self))
        let dslSoto = try captured.toSotoPutItemInput()

        #expect(dslSoto.returnValuesOnConditionCheckFailure == .allOld)
    }

    @Test("UpdateItem: .returnConflictingItem() flips ALL_OLD on the wire")
    func updateReturnConflictingItemFlipsAllOld() async throws {
        let client = RecordingDynamoClient()
        try await PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        } where: { column in
            column.status != "processing"
        }
        .returnConflictingItem()
        .execute(using: client)
        let captured = try #require(await client.lastUpdateInput(for: PhotoScan.self))
        let dslSoto = captured.toSotoUpdateItemInput()

        #expect(dslSoto.returnValuesOnConditionCheckFailure == .allOld)
    }

    @Test("DeleteItem: .returnConflictingItem() flips ALL_OLD on the wire")
    func deleteReturnConflictingItemFlipsAllOld() async throws {
        let client = RecordingDynamoClient()
        try await HikerHandle.delete(partitionKey: "alice") { column in
            column.hikerId == "hiker-123"
        }
        .returnConflictingItem()
        .execute(using: client)
        let captured = try #require(await client.lastDeleteInput(for: HikerHandle.self))
        let dslSoto = captured.toSotoDeleteItemInput()

        #expect(dslSoto.returnValuesOnConditionCheckFailure == .allOld)
    }

    @Test("Catch site receives ConditionalCheckFailed<Model> with the prior item")
    func catchSiteReceivesPriorItem() async throws {
        let client = RecordingDynamoClient()
        let prior = HikerHandle(handleLower: "alice", hikerId: "hiker-OTHER")
        await client.throwOnDelete(
            ConditionalCheckFailed<HikerHandle>(
                tableName: "TrailHikerHandles",
                priorItem: prior
            ),
            for: HikerHandle.self
        )

        do {
            try await HikerHandle.delete(partitionKey: "alice") { column in
                column.hikerId == "hiker-123"
            }
            .returnConflictingItem()
            .execute(using: client)
            Issue.record("expected ConditionalCheckFailed to throw")
        } catch let conflict as ConditionalCheckFailed<HikerHandle> {
            #expect(conflict.tableName == "TrailHikerHandles")
            #expect(conflict.priorItem?.hikerId == "hiker-OTHER")
            #expect(conflict.priorItem?.handleLower == "alice")
        }
    }

    @Test("Catch site sees nil priorItem when modifier wasn't requested")
    func catchSiteWithoutModifierSeesNilPrior() async throws {
        let client = RecordingDynamoClient()
        await client.throwOnPut(
            ConditionalCheckFailed<TrailCard>(
                tableName: "TrailCards",
                priorItem: nil
            ),
            for: TrailCard.self
        )

        let chart = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1735776000.0
        )
        do {
            try await chart.put { column in column.cardTokenHash.doesNotExist }
                .execute(using: client)
            Issue.record("expected ConditionalCheckFailed to throw")
        } catch let conflict as ConditionalCheckFailed<TrailCard> {
            #expect(conflict.priorItem == nil)
        }
    }
}

// MARK: - Pagination

@Suite("Page streaming")
struct PaginationTests {

    @Test("Query: pages(using:) iterates lazily and threads the start token")
    func queryPagesIteratesAndThreadsToken() async throws {
        let client = RecordingDynamoClient()
        let token1 = PaginationToken(key: ["hikerId": .string("hiker-1")])
        let token2 = PaginationToken(key: ["hikerId": .string("hiker-2")])
        await client.seedQueryPages(
            [
                QueryPage(items: [
                    HikingSession(hikerId: "hiker-a", sessionNumber: 1),
                    HikingSession(hikerId: "hiker-a", sessionNumber: 2),
                ], nextToken: token1),
                QueryPage(items: [
                    HikingSession(hikerId: "hiker-b", sessionNumber: 1),
                ], nextToken: token2),
                QueryPage(items: [
                    HikingSession(hikerId: "hiker-c", sessionNumber: 1),
                ], nextToken: nil),
            ],
            for: HikingSession.self
        )

        var collected: [HikingSession] = []
        let pages = HikingSession.query { column in
            Key { column.hikerId == "hiker-a" }
        }
        .pages(using: client)
        for try await page in pages {
            collected.append(contentsOf: page.items)
        }

        #expect(collected.count == 4)
        let recorded = await client.recordedQueryInputs(for: HikingSession.self)
        #expect(recorded.count == 3)
        // Page 1 starts with no token; pages 2 and 3 carry forward the
        // token from the previous response.
        #expect(recorded[0].exclusiveStartKey == nil)
        #expect(recorded[1].exclusiveStartKey == token1.key)
        #expect(recorded[2].exclusiveStartKey == token2.key)
    }

    @Test("Query: pages(using:) is lazy — early break stops further fetches")
    func queryPagesIsLazy() async throws {
        let client = RecordingDynamoClient()
        let token1 = PaginationToken(key: ["hikerId": .string("hiker-1")])
        await client.seedQueryPages(
            [
                QueryPage(items: [HikingSession(hikerId: "hiker-a", sessionNumber: 1)], nextToken: token1),
                QueryPage(items: [HikingSession(hikerId: "hiker-b", sessionNumber: 1)], nextToken: nil),
            ],
            for: HikingSession.self
        )

        let pages = HikingSession.query { column in
            Key { column.hikerId == "hiker-a" }
        }
        .pages(using: client)
        var iterator = pages.makeAsyncIterator()
        _ = try await iterator.next()  // pull only the first page
        // Drop the iterator without ever asking for the second page.

        let recorded = await client.recordedQueryInputs(for: HikingSession.self)
        #expect(recorded.count == 1)
    }

    @Test("Query: executeAll() collects every item across pages")
    func queryExecuteAllCollects() async throws {
        let client = RecordingDynamoClient()
        let token = PaginationToken(key: ["hikerId": .string("hiker-mid")])
        await client.seedQueryPages(
            [
                QueryPage(items: [
                    HikingSession(hikerId: "hiker-a", sessionNumber: 1),
                ], nextToken: token),
                QueryPage(items: [
                    HikingSession(hikerId: "hiker-b", sessionNumber: 1),
                    HikingSession(hikerId: "hiker-c", sessionNumber: 1),
                ], nextToken: nil),
            ],
            for: HikingSession.self
        )

        let items = try await HikingSession.query { column in
            Key { column.hikerId == "hiker-a" }
        }
        .executeAll(using: client)

        #expect(items.count == 3)
        let recorded = await client.recordedQueryInputs(for: HikingSession.self)
        #expect(recorded.count == 2)
        #expect(recorded[0].exclusiveStartKey == nil)
        #expect(recorded[1].exclusiveStartKey == token.key)
    }

    @Test("Scan: pages(using:) iterates and threads the start token")
    func scanPagesIteratesAndThreadsToken() async throws {
        let client = RecordingDynamoClient()
        let token = PaginationToken(key: ["batchId": .string("batch-1")])
        await client.seedScanPages(
            [
                QueryPage(items: [PendingHikeBatch(batchId: "batch-1", attempts: 0)], nextToken: token),
                QueryPage(items: [PendingHikeBatch(batchId: "batch-2", attempts: 1)], nextToken: nil),
            ],
            for: PendingHikeBatch.self
        )

        var collected: [PendingHikeBatch] = []
        for try await page in PendingHikeBatch.scan().pages(using: client) {
            collected.append(contentsOf: page.items)
        }

        #expect(collected.count == 2)
        let recorded = await client.recordedScanInputs(for: PendingHikeBatch.self)
        #expect(recorded.count == 2)
        #expect(recorded[0].exclusiveStartKey == nil)
        #expect(recorded[1].exclusiveStartKey == token.key)
    }
}
