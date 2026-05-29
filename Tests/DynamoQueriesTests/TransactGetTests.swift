import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// Read transactions (`TransactGetItems`). The decode/ordering path can't be
// exercised against a live table here, so these cover the two seams that the
// DSL actually owns: (1) the legs that go over the wire, in order, with the
// right keys, and (2) that the typed result tuple threads back positionally —
// including `nil` for a not-found leg.

@Suite("TransactGet")
struct TransactGetTests {

    @Test("Legs are submitted in declaration order with the right keys")
    func submitsLegsInOrder() async throws {
        let client = RecordingDynamoClient()
        _ = try await TransactGet {
            try PhotoScan.get(partitionKey: "scan-1")
            try HikingSession.get(partitionKey: "hiker-9", sortKey: 3)
        }
        .execute(using: client)

        let tables = try #require(await client.lastTransactGetTables)
        let keys = try #require(await client.lastTransactGetKeys)
        #expect(tables == ["TrailPhotoScans", "TrailHikingSessions"])
        #expect(keys[0] == ["id": .string("scan-1")])
        #expect(keys[1] == ["hikerId": .string("hiker-9"), "sessionNumber": .number("3")])
    }

    @Test("Returns a typed tuple in declaration order, nil for misses")
    func decodesTupleInOrder() async throws {
        let client = RecordingDynamoClient()
        let scan = PhotoScan(id: "scan-1", status: "done", updatedAt: 1, reason: nil)
        // Leg 0 found, leg 1 not found.
        await client.seedTransactGetResults([scan, nil])

        let (photo, session): (PhotoScan?, HikingSession?) = try await TransactGet {
            try PhotoScan.get(partitionKey: "scan-1")
            try HikingSession.get(partitionKey: "hiker-9", sortKey: 3)
        }
        .execute(using: client)

        #expect(photo?.id == "scan-1")
        #expect(photo?.status == "done")
        #expect(session == nil)
    }

    @Test("A single leg converts to a Soto Get with the table suffix applied")
    func legConvertsToSotoGet() throws {
        let get = try PhotoScan.get(partitionKey: "scan-1")
        let resolved = get.toSotoGet(tableNameOverride: "TrailPhotoScans-prod")

        let reference = DynamoDB.Get(
            key: ["id": .s("scan-1")],
            tableName: "TrailPhotoScans-prod"
        )
        #expect(resolved.key == reference.key)
        #expect(resolved.tableName == reference.tableName)
    }
}
