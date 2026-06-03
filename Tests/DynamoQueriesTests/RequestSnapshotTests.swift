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
    func getSnapshot() {
        assertInlineSnapshot(of: PhotoScan.get(partitionKey: "scan-1"), as: .request) {
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

    @Test("A transact write renders to a stable request snapshot")
    func transactWriteSnapshot() throws {
        let card = TrailCard(
            cardTokenHash: "hash-9f",
            ownerId: "hiker-1",
            createdAt: 1_735_776_000
        )

        try assertInlineSnapshot(
            of: TransactWriteInput {
                card.put { $0.cardTokenHash.doesNotExist }
                PhotoScan.update(partitionKey: "scan-abc") { column in
                    column.status.set(to: "processing")
                } where: { column in
                    column.status != "processing"
                }
                HikerHandle.delete(partitionKey: "alice") { column in
                    column.hikerId == "hiker-OTHER"
                }
                try DifficultyScore.conditionCheck(partitionKey: "score-1") { column in
                    column.lastClimbedAt == 1_735_776_000
                }
            },
            as: .request
        ) {
            """
            TransactWrite
              [0] Put TrailCards
                item: {"cardTokenHash":"hash-9f","createdAt":1735776000,"ownerId":"hiker-1"}
                condition: attribute_not_exists(#n0)
                names: { #n0: cardTokenHash }
              [1] Update TrailPhotoScans
                key: { id: S("scan-abc") }
                update: SET #n0 = :v0
                condition: #n1 <> :v1
                names: { #n0: status, #n1: status }
                values: { :v0: S("processing"), :v1: S("processing") }
              [2] Delete TrailHikerHandles
                key: { handleLower: S("alice") }
                condition: #n0 = :v0
                names: { #n0: hikerId }
                values: { :v0: S("hiker-OTHER") }
              [3] ConditionCheck TrailDifficultyScores
                key: { id: S("score-1") }
                condition: #n0 = :v0
                names: { #n0: lastClimbedAt }
                values: { :v0: N(1735776000.0) }
            """
        }
    }

    @Test("A transact get renders to a stable request snapshot")
    func transactGetSnapshot() {
        assertInlineSnapshot(
            of: TransactGet {
                PhotoScan.get(partitionKey: "scan-1")
                HikingSession.get(partitionKey: "hiker-1", sortKey: 7)
                    .project(HikingSession.columns.hikerId)
            },
            as: .request
        ) {
            """
            TransactGet
              [0] Get TrailPhotoScans
                key: { id: S("scan-1") }
              [1] Get TrailHikingSessions
                key: { hikerId: S("hiker-1"), sessionNumber: N(7) }
                project: hikerId
            """
        }
    }

    @Test("A stub client transcript snapshots a request sequence")
    func transcriptSnapshot() async throws {
        let client = RecordingDynamoClient()
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
