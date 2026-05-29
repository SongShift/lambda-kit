import DynamoQueries
import DynamoQueriesSoto
import DynamoQueriesTestSupport
import Foundation
import SotoDynamoDB
import Testing

// Read transactions (`TransactGetItems`). The decode/ordering path can't be
// exercised against a live table here, so these cover the seams the DSL owns:
// (1) the legs that go over the wire, in order, with the right keys and storage
// metatypes; (2) that the typed result tuple threads back positionally, with
// `nil` for a not-found leg; and (3) that a `.map`-ped leg composes alongside a
// raw leg and delivers the transformed type.

private struct ScanView: Equatable {
    let id: String
    let done: Bool
}

@Suite("TransactGet")
struct TransactGetTests {

    @Test("Legs are submitted in declaration order with the right keys/types")
    func submitsLegsInOrder() async throws {
        let client = RecordingDynamoClient()
        _ = try await TransactGet {
            try PhotoScan.get(partitionKey: "scan-1")
            try HikingSession.get(partitionKey: "hiker-9", sortKey: 3)
        }
        .execute(using: client)

        let items = try #require(await client.lastTransactGetItems)
        #expect(items.map(\.tableName) == ["TrailPhotoScans", "TrailHikingSessions"])
        #expect(items[0].key == ["id": .string("scan-1")])
        #expect(items[1].key == ["hikerId": .string("hiker-9"), "sessionNumber": .number("3")])
        #expect(ObjectIdentifier(items[0].modelType) == ObjectIdentifier(PhotoScan.self))
        #expect(ObjectIdentifier(items[1].modelType) == ObjectIdentifier(HikingSession.self))
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

    @Test("A mapped leg composes with a raw leg and delivers the transformed type")
    func mappedLegComposes() async throws {
        let client = RecordingDynamoClient()
        let scan = PhotoScan(id: "scan-1", status: "done", updatedAt: 1, reason: nil)
        let session = HikingSession(hikerId: "hiker-9", sessionNumber: 3)
        await client.seedTransactGetResults([scan, session])

        // Leg 0 is mapped to a domain view; leg 1 is a raw model.
        let (view, raw): (ScanView?, HikingSession?) = try await TransactGet {
            try PhotoScan.get(partitionKey: "scan-1")
                .map { ScanView(id: $0.id, done: $0.status == "done") }
            try HikingSession.get(partitionKey: "hiker-9", sortKey: 3)
        }
        .execute(using: client)

        #expect(view == ScanView(id: "scan-1", done: true))
        #expect(raw?.sessionNumber == 3)
        // The wire request still carries the *storage* metatype, not the view.
        let items = try #require(await client.lastTransactGetItems)
        #expect(ObjectIdentifier(items[0].modelType) == ObjectIdentifier(PhotoScan.self))
    }

    @Test("A standalone mapped get passes nil through on a miss (no transform)")
    func mappedGetStandaloneMiss() async throws {
        let client = RecordingDynamoClient()  // getItem returns nil

        let view = try await PhotoScan.get(partitionKey: "missing")
            .map { ScanView(id: $0.id, done: $0.status == "done") }
            .execute(using: client)

        #expect(view == nil)
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
