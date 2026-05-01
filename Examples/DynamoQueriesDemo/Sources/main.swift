//
//  DynamoQueriesDemo
//
//  A tour of the major DynamoQueries operations. Runs against an in-memory
//  RecordingClient that prints what each DSL call site renders to.
//

import Foundation
import DynamoQueries

// MARK: - 1. Models

@Table("DemoHikers")
@Index("emailIndex", partitionKey: "email")
struct Hiker: Codable, Sendable {
    @PartitionKey var id: String
    var email: String
    var displayName: String
    var createdAt: Double
    var hikeCount: Int = 0
    var isVerified: Bool = false
}

@Table("DemoHikes")
struct Hike: Codable, Sendable {
    @PartitionKey var hikerID: String
    @SortKey var hikeID: String
    var trailName: String
    var distanceMiles: Double
    var elevationGainFeet: Int
    var rating: Int
    var status: String
}

// MARK: - 2. Recording client

/// Captures every DSL-built input, prints what the wire-level request looks
/// like, and hands back canned responses. Real adapters live in
/// `DynamoQueriesSoto`.
actor RecordingClient: DynamoClient {
    func execute<Model: DynamoModel>(_ input: QueryInput<Model>) async throws -> QueryPage<Model> {
        print("""
        Query \(input.tableName)\(input.indexName.map { " on \($0)" } ?? "")
            keyCondition: \(input.keyConditionExpression)
            filter:       \(input.filterExpression ?? "(none)")
            names:        \(input.expressionAttributeNames)
            values:       \(input.expressionAttributeValues)
        """)
        return QueryPage(items: [], nextToken: nil)
    }

    func getItem<Model: DynamoModel>(_ input: GetItemInput<Model>) async throws -> Model? {
        print("GetItem \(input.tableName) key=\(input.key)")
        return nil
    }

    func putItem<Model: DynamoModel>(_ input: PutItemInput<Model>) async throws {
        print("""
        PutItem \(input.tableName)
            condition: \(input.conditionExpression ?? "(none)")
        """)
    }

    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>) async throws {
        print("""
        UpdateItem \(input.tableName)
            update:    \(input.updateExpression)
            condition: \(input.conditionExpression ?? "(none)")
        """)
    }

    func updateItemReturning<Model: DynamoModel>(_ input: UpdateReturning<Model>) async throws -> Model? {
        try await updateItem(input.input)
        return nil
    }

    func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>) async throws {
        print("DeleteItem \(input.tableName) key=\(input.key)")
    }

    func scan<Model: DynamoModel>(_ input: ScanInput<Model>) async throws -> QueryPage<Model> {
        print("Scan \(input.tableName) filter=\(input.filterExpression ?? "(none)")")
        return QueryPage(items: [], nextToken: nil)
    }

    func count<Model: DynamoModel>(_ input: QueryInput<Model>) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    func count<Model: DynamoModel>(_ input: ScanInput<Model>) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    func batchGet<Model: DynamoModel>(_ input: BatchGetInput<Model>) async throws -> [Model] {
        print("BatchGet \(input.tableName) keys=\(input.keys.count)")
        return []
    }

    func batchWrite<Model: DynamoModel>(_ input: BatchWriteInput<Model>) async throws {
        print("BatchWrite \(input.tableName) puts=\(input.putItems.count) deletes=\(input.deleteKeys.count)")
    }

    func transactWrite(_ items: [TransactWriteItem]) async throws {
        print("TransactWrite legs=\(items.count)")
    }
}

// MARK: - 3. Walk-through

let client = RecordingClient()

print("\n— Query: pk + begins_with(sk) + filter -—————————————————————————")
_ = try await Hike.query { hike in
    Key {
        hike.hikerID == "hiker-1"
        hike.hikeID.beginsWith("2026-")
    }
    Filter {
        hike.status != "abandoned"
        hike.distanceMiles > 5
    }
}
.execute(using: client)

print("\n— Query: GSI, descending, limit -——————————————————————————————————")
_ = try await Hiker.query { hiker in
    Key { hiker.email == "ada@example.com" }
}
.on(Hiker.Indexes.emailIndex)
.scanIndexForward(false)
.limit(10)
.execute(using: client)

print("\n— PutItem: insert-only-if-not-present -—————————————————————————————")
let newHiker = Hiker(
    id: "hiker-123",
    email: "ada@example.com",
    displayName: "Ada Lovelace",
    createdAt: Date().timeIntervalSince1970
)
try await newHiker.put { h in h.id.doesNotExist }.execute(using: client)

print("\n— UpdateItem: optimistic-concurrency counter bump -—————————————————")
try await Hiker.update(
    partitionKey: "hiker-123",
    {
        $0.hikeCount.add(1)
        $0.isVerified.set(to: true)
    },
    where: { $0.id.exists }
)
.execute(using: client)

print("\n— Scan: filter only, last-resort access pattern -———————————————————")
_ = try await Hike.scan { h in
    h.status == "in_progress"
}
.execute(using: client)

print("\n— BatchWrite: bulk puts + a delete -————————————————————————————————")
try await Hiker.batchWrite()
    .put(newHiker)
    .put(Hiker(
        id: "hiker-124",
        email: "grace@example.com",
        displayName: "Grace Hopper",
        createdAt: Date().timeIntervalSince1970
    ))
    .delete(partitionKey: "hiker-deprecated")
    .execute(using: client)

print("\n— TransactWrite: atomic multi-table update -—————————————————————————")
try await TransactWriteInput {
    newHiker.put { $0.id.doesNotExist }
    try Hike.update(
        partitionKey: "hiker-1",
        sortKey: "2026-001",
        { $0.status.set(to: "completed") }
    )
    try Hike.conditionCheck(
        partitionKey: "hiker-1",
        sortKey: "2026-002"
    ) { $0.status == "in_progress" }
}
.execute(using: client)

print("\nDone.\n")
