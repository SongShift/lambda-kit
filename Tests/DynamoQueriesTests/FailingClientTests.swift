import DynamoQueries
import DynamoQueriesTestSupport
import Foundation
import Testing

// Testing error handling with `FailingDynamoClient` + the agnostic `expect*`
// helpers. The client throws a chosen error on the operations you point it at;
// the helper asserts the operation surfaces it and hands back the typed error.

// A service that reads then writes, used to show scoped failure.
private struct ReviewService {
    let client: any DynamoClient

    func review(id: String) async throws {
        _ = try await PhotoScan.get(partitionKey: id).execute(using: client)        // read
        try await PhotoScan(id: id, status: "reviewed", updatedAt: 0, reason: nil)
            .put { $0.id.exists }
            .execute(using: client)                                                 // write
    }
}

@Suite("FailingDynamoClient")
private struct FailingClientTests {

    @Test("Fails every operation by default — including reads")
    func failsReadsByDefault() async throws {
        let client = FailingDynamoClient(reason: .accessDenied)

        let failure = try await expectDynamoFailure(.accessDenied) {
            _ = try await PhotoScan.get(partitionKey: "s1").execute(using: client)
        }
        #expect(failure.isRetryable == false)
    }

    @Test("Scoped to writes: the read succeeds, only the write throttles")
    func scopedToWrites() async throws {
        // get returns nil (benign); put throws, so reaching the failure proves
        // the read wasn't what failed.
        let client = FailingDynamoClient(reason: .throttled, on: .writes)

        let failure = try await expectDynamoFailure(.throttled) {
            try await ReviewService(client: client).review(id: "s1")
        }
        #expect(failure.isRetryable)
    }

    @Test("Throws a typed ConditionalCheckFailed the service can catch")
    func conditionalCheckFailure() async throws {
        let client = FailingDynamoClient(
            ConditionalCheckFailed<PhotoScan>(tableName: "TrailPhotoScans", priorItem: nil)
        )

        let failure = try await expectConditionalCheckFailure(of: PhotoScan.self) {
            try await PhotoScan(id: "s1", status: "new", updatedAt: 0, reason: nil)
                .put { $0.id.doesNotExist }
                .execute(using: client)
        }
        #expect(failure.tableName == "TrailPhotoScans")
    }

    @Test("Conditional conflict returns the prior item only when opted in")
    func conflictHonorsReturnConflictingItem() async throws {
        let prior = PhotoScan(id: "s1", status: "done", updatedAt: 9, reason: nil)
        let client = FailingDynamoClient.conditionalConflict(
            for: PhotoScan.self,
            tableName: "TrailPhotoScans",
            conflictingItem: prior
        )

        // Opted in via `.returnConflictingItem()` → priorItem is populated.
        let withPrior = try await expectConditionalCheckFailure(of: PhotoScan.self) {
            try await PhotoScan(id: "s1", status: "new", updatedAt: 10, reason: nil)
                .put { $0.id.doesNotExist }
                .returnConflictingItem()
                .execute(using: client)
        }
        #expect(withPrior.priorItem?.status == "done")
        #expect(withPrior.tableName == "TrailPhotoScans")

        // No opt-in → priorItem is nil, mirroring a real adapter.
        let withoutPrior = try await expectConditionalCheckFailure(of: PhotoScan.self) {
            try await PhotoScan(id: "s1", status: "new", updatedAt: 10, reason: nil)
                .put { $0.id.doesNotExist }
                .execute(using: client)
        }
        #expect(withoutPrior.priorItem == nil)
    }

    @Test("expectError catches an arbitrary error type")
    func arbitraryError() async throws {
        struct Boom: Error, Equatable {}
        let client = FailingDynamoClient(Boom())

        let error = try await expectError(Boom.self) {
            _ = try await PhotoScan.query { p in Key { p.id == "s1" } }.execute(using: client)
        }
        #expect(error == Boom())
    }
}
