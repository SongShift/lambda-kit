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

// Domain model — what the service layer actually works with.  Repositories
// convert between this and the DynamoDB storage model (Hiker / Hike).
struct DomainHiker: Sendable {
    var id: String
    var email: String
    var displayName: String
    var hikeCount: Int
    var isVerified: Bool
}

struct DomainHike: Sendable {
    var hikerID: String
    var hikeID: String
    var trailName: String
    var status: String
}

extension Hiker {
    func toDomain() -> DomainHiker {
        DomainHiker(id: id, email: email, displayName: displayName,
                    hikeCount: hikeCount, isVerified: isVerified)
    }
}

extension Hike {
    func toDomain() -> DomainHike {
        DomainHike(hikerID: hikerID, hikeID: hikeID,
                   trailName: trailName, status: status)
    }
}

struct HikerRepository {

    func fetch(id: String) throws -> MappedGet<Hiker, DomainHiker> {
        try Hiker.get(partitionKey: id).map { $0.toDomain() }
    }

    
    func fetchMany(ids: [String]) throws -> MappedBatchGet<Hiker, DomainHiker> {
        try Hiker.batchGet(partitionKeys: ids).map { $0.toDomain() }
    }

    // MARK: Writes

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

    // MARK: Reads

    func fetch(hikerID: String, hikeID: String) throws -> MappedGet<Hike, DomainHike> {
        try Hike.get(partitionKey: hikerID, sortKey: hikeID).map { $0.toDomain() }
    }

    func fetchMany(keys: [(hikerID: String, hikeID: String)]) throws -> MappedBatchGet<Hike, DomainHike> {
        try Hike.batchGet(keys: keys.map { (partitionKey: $0.hikerID, sortKey: $0.hikeID) })
            .map { $0.toDomain() }
    }

    func scanByStatus(_ status: String) -> MappedScan<Hike, DomainHike> {
        Hike.scan { $0.status == status }
            .map { $0.toDomain() }
    }

    // MARK: Writes

    func record(_ hike: Hike) -> PutItemInput<Hike> {
       return hike.put { $0.hikeID.doesNotExist }
    }

    func setStatus(hikerID: String, hikeID: String, to status: String) throws -> UpdateInput<Hike> {
        try Hike.update(partitionKey: hikerID, sortKey: hikeID) {
            $0.status.set(to: status)
        } where: { $0.hikerID.exists }
    }

    func cancelMany(_ ids: [(hikerID: String, hikeID: String)]) throws -> [UpdateInput<Hike>] {
        try ids.map { id in
            try Hike.update(partitionKey: id.hikerID, sortKey: id.hikeID) {
                $0.status.set(to: "cancelled")
            }
        }
    }
}

struct TrailService {
    let client: any DynamoClient
    let hikers: HikerRepository
    let hikes: HikeRepository

    func snapshot(hikerID: String, hikeID: String) async throws -> (DomainHiker?, DomainHike?) {
        try await TransactGet {
            try hikers.fetch(id: hikerID)
            try hikes.fetch(hikerID: hikerID, hikeID: hikeID)
        }
        .execute(using: client)
    }

    func hiker(id: String) async throws -> DomainHiker? {
        try await hikers.fetch(id: id).execute(using: client)
    }

    func roster(ids: [String]) async throws -> [DomainHiker] {
        try await hikers.fetchMany(ids: ids).execute(using: client)
    }

    func activeHikes() async throws -> [DomainHike] {
        try await hikes.scanByStatus("in_progress").executeAll(using: client)
    }

    func bulkLoad(
        hikerIDs: [String],
        hikeKeys: [(hikerID: String, hikeID: String)]
    ) async throws -> (hikers: [DomainHiker], hikes: [DomainHike]) {
        async let people = hikers.fetchMany(ids: hikerIDs).execute(using: client)
        async let logged = hikes.fetchMany(keys: hikeKeys).execute(using: client)
        return try await (people, logged)
    }

    func registerFirstHike(_ hiker: Hiker, firstHike: Hike) async throws {
        try await TransactWriteInput {
            hikers.create(hiker)
            hikes.record(firstHike)
            try hikers.markVerified(id: hiker.id)
        }
        .execute(using: client)
    }

    // Atomic read to load current state; atomic write to commit the transition.
    // The guard on the snapshot result is where business logic would live in a
    // real implementation — e.g. checking hike.status before allowing completion.
    func completeHike(hikerID: String, hikeID: String) async throws {
        let (hiker, hike) = try await snapshot(hikerID: hikerID, hikeID: hikeID)
        print("  snapshot → hiker=\(hiker != nil) hike=\(hike != nil)")
        guard hiker != nil, hike != nil else { return }

        try await TransactWriteInput {
            try hikes.setStatus(hikerID: hikerID, hikeID: hikeID, to: "completed")
            try hikers.incrementHikeCount(id: hikerID)
        }
        .execute(using: client)
    }
}

let hikerRepo = HikerRepository()
let hikeRepo = HikeRepository()
let service = TrailService(client: client, hikers: hikerRepo, hikes: hikeRepo)

let edith = Hiker(
    id: "hiker-200",
    email: "edith@example.com",
    displayName: "Edith Clarke",
    createdAt: Date().timeIntervalSince1970
)
let firstHike = Hike(
    hikerID: "hiker-200",
    hikeID: "2026-001",
    trailName: "Skyline",
    distanceMiles: 7.2,
    elevationGainFeet: 900,
    rating: 4,
    status: "in_progress"
)

print("\n— Service: register first hike (atomic write across both repos) -—————————")
try await service.registerFirstHike(edith, firstHike: firstHike)

print("\n— Service: standalone read via mapped fetch (transform declared in repo) -")
let domainHiker = try await service.hiker(id: "hiker-200")
print("hiker found: \(domainHiker != nil)")

print("\n— Service: snapshot (atomic read; mapped legs deliver domain types) -——")
let (snapHiker, snapHike) = try await service.snapshot(hikerID: "hiker-200", hikeID: "2026-001")
print("snapshot → hiker=\(snapHiker != nil) hike=\(snapHike != nil)")

print("\n— Service: batch read — transform declared in repo, service just executes -")
let roster = try await service.roster(ids: ["hiker-200", "hiker-201", "hiker-202"])
print("roster loaded: \(roster.count)")

print("\n— Service: scan — standalone read, can't be a TransactGet leg -—————————")
let active = try await service.activeHikes()
print("active hikes: \(active.count)")

print("\n— Service: concurrent batch reads across both repos -———————————————————")
let bulk = try await service.bulkLoad(
    hikerIDs: ["hiker-200", "hiker-201"],
    hikeKeys: [
        (hikerID: "hiker-200", hikeID: "2026-001"),
        (hikerID: "hiker-200", hikeID: "2026-002"),
    ]
)
print("bulk loaded: hikers=\(bulk.hikers.count) hikes=\(bulk.hikes.count)")

print("\n— Service: complete hike (atomic read then atomic write) -—————————————")
try await service.completeHike(hikerID: "hiker-200", hikeID: "2026-001")

print("\n— Repository: array of writables flattens automatically -——————————————")
try await TransactWriteInput {
    try hikeRepo.cancelMany([
        (hikerID: "hiker-200", hikeID: "2026-002"),
        (hikerID: "hiker-200", hikeID: "2026-003"),
    ])
}
.execute(using: client)

print("\nDone.\n")
