import DynamoQueries
import DynamoQueriesTestSupport
import Foundation
import Testing


private struct ScanView: Equatable {
    let id: String
    let done: Bool
}

private struct PhotoScanRepository {

    func fetch(id: String) -> some Read<ScanView> {
        PhotoScan.get(partitionKey: id)
            .map { ScanView(id: $0.id, done: $0.status == "done") }
    }

    func markReviewed(id: String, at time: Double) -> PutItemInput<PhotoScan> {
        PhotoScan(id: id, status: "reviewed", updatedAt: time, reason: nil)
            .put { $0.id.exists }
    }
}

// MARK: - Tests

@Suite("PhotoScanRepository")
private struct PhotoScanRepositoryTests {

    @Test("fetch maps storage → domain and sends the right key")
    func fetchMapsAndSendsKey() async throws {
        let client = RecordingDynamoClient()
        await client.seedGetItem(
            PhotoScan(id: "scan-1", status: "done", updatedAt: 1, reason: nil),
            for: PhotoScan.self
        )

        let view = try await PhotoScanRepository().fetch(id: "scan-1").execute(using: client)

        #expect(view == ScanView(id: "scan-1", done: true))

        let sent = await client.lastGetInput(for: PhotoScan.self)
        #expect(sent?.tableName == "TrailPhotoScans")
        #expect(sent?.key == ["id": .string("scan-1")])
    }

    @Test("fetch passes a not-found through as nil (no mapping)")
    func fetchMissReturnsNil() async throws {
        let client = RecordingDynamoClient()  // nothing seeded → get returns nil

        let view = try await PhotoScanRepository().fetch(id: "missing").execute(using: client)

        #expect(view == nil)
    }

    @Test("markReviewed carries the existence condition and the new item")
    func markReviewedBuildsConditionalPut() async throws {
        let client = RecordingDynamoClient()

        try await PhotoScanRepository()
            .markReviewed(id: "scan-1", at: 42)
            .execute(using: client)

        let put = await client.lastPutInput(for: PhotoScan.self)
        #expect(put?.item.status == "reviewed")
        #expect(put?.item.updatedAt == 42)
        #expect(put?.conditionExpression != nil)  // `$0.id.exists`
    }

    @Test("a conditional failure from the wire surfaces to the caller")
    func putErrorPropagates() async throws {
        struct Boom: Error {}
        let client = RecordingDynamoClient()
        await client.throwOnPut(Boom(), for: PhotoScan.self)

        await #expect(throws: Boom.self) {
            try await PhotoScanRepository()
                .markReviewed(id: "scan-1", at: 42)
                .execute(using: client)
        }
    }
}
