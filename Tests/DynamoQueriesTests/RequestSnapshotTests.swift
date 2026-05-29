import DynamoQueries
import DynamoQueriesSnapshotTesting
import DynamoQueriesTestSupport
import Foundation
import InlineSnapshotTesting
import SnapshotTesting
import Testing

@Suite("RequestSnapshots")
struct RequestSnapshotTests {

    @Test("A query renders to a stable request snapshot")
    func querySnapshot() {
        assertInlineSnapshot(
            of: TrailRoute.query { r in
                Key {
                    r.hikerId == "hiker-1"
                    r.createdAt > 100
                }
                Filter { r.nameLower.beginsWith("a") }
            }
            .usingIndex(TrailRoute.Indexes.hikerCreatedAtIndex)
            .scanIndexForward(false)
            .limit(10),
            as: .request
        ) {
            """
            Query TrailRoutes on hikerCreatedAtIndex
              key: (#n0 = :v0) AND (#n1 > :v1)
              filter: begins_with(#n2, :v2)
              names: { #n0: hikerId, #n1: createdAt, #n2: nameLower }
              values: { :v0: S("hiker-1"), :v1: N(100.0), :v2: S("a") }
              scanForward: false
              limit: 10
            """
        }
    }

    @Test("A get renders to a stable request snapshot")
    func getSnapshot() throws {
        try assertInlineSnapshot(of: PhotoScan.get(partitionKey: "scan-1"), as: .request) {
            """
            GetItem TrailPhotoScans
              key: { id: S("scan-1") }
            """
        }
    }

    @Test("A scan renders to a stable request snapshot")
    func scanSnapshot() {
        assertInlineSnapshot(
            of: HikingSession.scan { $0.sessionNumber > 2 },
            as: .request
        ) {
            """
            Scan TrailHikingSessions
              filter: #n0 > :v0
              names: { #n0: sessionNumber }
              values: { :v0: N(2) }
            """
        }
    }

    @Test("A stub client transcript snapshots a request sequence")
    func transcriptSnapshot() async throws {
        let client = StubDynamoClient()
        _ = try await PhotoScan.get(partitionKey: "scan-1").execute(using: client)
        _ = try await HikingSession.scan { $0.sessionNumber > 2 }.execute(using: client)

        let transcript = await client.transcript
        assertInlineSnapshot(of: transcript, as: .lines) {
            """
            GetItem TrailPhotoScans
              key: { id: S("scan-1") }

            Scan TrailHikingSessions
              filter: #n0 > :v0
              names: { #n0: sessionNumber }
              values: { :v0: N(2) }
            """
        }
    }
}
