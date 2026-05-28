//
//  DynamoQueriesDemo
//
//  A tour of the major DynamoQueries operations. Runs against an in-memory
//  RecordingClient that prints what each DSL call site renders to.
//

import Foundation
import DynamoQueries

// MARK: Models

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

// MARK: Walk-through

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
.usingIndex(Hiker.Indexes.emailIndex)
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

print("\n— TransactGet: atomic, serializable multi-item read -—————————————————")

let (snapshotHiker, snapshotHike): (Hiker?, Hike?) = try await TransactGet {
    try Hiker.get(partitionKey: "hiker-123")
    try Hike.get(partitionKey: "hiker-1", sortKey: "2026-001")
}
.execute(using: client)

print("hiker found: \(snapshotHiker != nil), hike found: \(snapshotHike != nil)")


// MARK: Repositories and services

// Repositories own a single aggregate and are *pure builders*: every method
// returns either a read leg (`GetItemInput`) or a writable (`TransactWritable`).
//
// Services own a unit of work. They inject the repositories they need, decide
// where the atomic boundary sits, and are the only layer that calls
// `.execute(using:)`. Keeping transaction boundaries out of the repositories is
// what lets one service operation compose legs from *several* repositories into
// a single all-or-nothing read or write if each repository committed its own
// transaction, a later failure would leave partial state behind.

struct HikerRepository {

    func fetch(id: String) throws -> GetItemInput<Hiker> {
        try Hiker.get(partitionKey: id)
    }

    func fetchMany(ids: [String]) throws -> BatchGetInput<Hiker> {
        try Hiker.batchGet(partitionKeys: ids)
    }

    // MARK: Writes — return writables the service composes into one transaction.

    func create(_ hiker: Hiker) -> PutItemInput<Hiker> {
        hiker.put { $0.id.doesNotExist }
    }

    func markVerified(id: String) throws -> UpdateInput<Hiker> {
        try Hiker.update(partitionKey: id) {
            $0.isVerified.set(to: true)
        } where: { $0.id.exists }
    }

    func incrementHikeCount(id: String) throws -> UpdateInput<Hiker> {
        try Hiker.update(partitionKey: id) {
            $0.hikeCount.add(1)
        } where: { $0.id.exists }
    }
}

struct HikeRepository {

    func fetch(hikerID: String, hikeID: String) throws -> GetItemInput<Hike> {
        try Hike.get(partitionKey: hikerID, sortKey: hikeID)
    }

    func fetchMany(keys: [(hikerID: String, hikeID: String)]) throws -> BatchGetInput<Hike> {
        try Hike.batchGet(keys: keys.map { (partitionKey: $0.hikerID, sortKey: $0.hikeID) })
    }

    func record(_ hike: Hike) -> any TransactWritable {
        hike.put { $0.hikeID.doesNotExist }
    }

    func setStatus(hikerID: String, hikeID: String, to status: String) throws -> UpdateInput<Hike> {
        try Hike.update(partitionKey: hikerID, sortKey: hikeID) {
            $0.status.set(to: status)
        } where: { $0.hikerID.exists }
    }

    /// One leg per id — the array flattens automatically inside a write block.
    func cancelMany(_ ids: [(hikerID: String, hikeID: String)]) throws -> [UpdateInput<Hike>] {
        try ids.map { id in
            try Hike.update(partitionKey: id.hikerID, sortKey: id.hikeID) {
                $0.status.set(to: "cancelled")
            }
        }
    }
}

/// A unit-of-work service composed over both repositories. It owns the client
/// and every transaction boundary; the repositories below it stay ignorant of
/// both.
struct TrailService {
    let client: any DynamoClient
    let hikers: HikerRepository
    let hikes: HikeRepository


    func snapshot(hikerID: String, hikeID: String) async throws -> (Hiker?, Hike?) {
        try await TransactGet {
            try hikers.fetch(id: hikerID)
            try hikes.fetch(hikerID: hikerID, hikeID: hikeID)
        }
        .execute(using: client)
    }

    func roster(ids: [String]) async throws -> [Hiker] {
        try await hikers.fetchMany(ids: ids).execute(using: client)
    }

    func bulkLoad(
        hikerIDs: [String],
        hikeKeys: [(hikerID: String, hikeID: String)]
    ) async throws -> (hikers: [Hiker], hikes: [Hike]) {
        async let people = hikers.fetchMany(ids: hikerIDs).execute(using: client)
        async let logged = hikes.fetchMany(keys: hikeKeys).execute(using: client)
        return try await (people, logged)
    }

    /// Insert the hiker, record their first hike, and flip the
    /// hiker to verified — all or nothing, legs drawn from both repositories.
    func registerFirstHike(_ hiker: Hiker, firstHike: Hike) async throws {
        try await TransactWriteInput {
            hikers.create(hiker)
            hikes.record(firstHike)
            try hikers.markVerified(id: hiker.id)
        }
        .execute(using: client)
    }

    /// Read *and* write in the same operation. The service runs an atomic read
    /// to load current state, then commits an atomic write — two distinct
    /// boundaries it alone controls. 
    func completeHike(hikerID: String, hikeID: String) async throws {
        let (hiker, hike) = try await snapshot(hikerID: hikerID, hikeID: hikeID)
      
        guard let hiker, let hike else {
            return
        }
        
        print(hiker, hike)
        
        try await TransactWriteInput {
            try hikes.setStatus(hikerID: hikerID, hikeID: hikeID, to: "completed")
            try hikers.incrementHikeCount(id: hikerID)
        }
        .execute(using: client)
    }
}
