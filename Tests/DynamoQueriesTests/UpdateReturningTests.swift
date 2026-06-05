import DynamoQueries
import DynamoQueriesTestSupport
import Testing

@Suite("UpdateReturning execution")
struct UpdateReturningTests {

    @Test("execute returns the item directly when attributes come back")
    func returnsItemDirectly() async throws {
        let client = RecordingDynamoClient()
        let updated = PhotoScan(id: "scan-1", status: "done", updatedAt: 2, reason: nil)
        await client.seedUpdateReturnItem(updated, for: PhotoScan.self)

        let result = try await PhotoScan.update(partitionKey: "scan-1") { column in
            column.status.set(to: "done")
        }
        .returnNewValues()
        .execute(using: client)

        #expect(result.id == updated.id)
        #expect(result.status == updated.status)
    }

    @Test("execute throws ReturnedAttributesNotFound when no attributes come back")
    func throwsWhenNoAttributesReturned() async throws {
        let client = RecordingDynamoClient()

        await #expect(throws: ReturnedAttributesNotFound<PhotoScan>.self) {
            try await PhotoScan.update(partitionKey: "scan-1") { column in
                column.status.set(to: "done")
            }
            .returnNewValues()
            .execute(using: client)
        }
    }

    @Test("ReturnedAttributesNotFound is not retryable")
    func notRetryable() {
        let error = ReturnedAttributesNotFound<PhotoScan>(tableName: "TrailPhotoScans")
        #expect(error.isRetryable == false)
        #expect(error.tableName == "TrailPhotoScans")
    }
}
