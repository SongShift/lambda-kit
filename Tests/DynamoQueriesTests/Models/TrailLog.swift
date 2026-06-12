import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB


// Binary keys in the source are modeled as `String` here: DynamoQueries'
// `DynamoValue` only understands string / number / bool, which is enough to
// exercise the compiler.

// MARK: - HikingSession (composite key)

@Table("TrailHikingSessions")
public struct HikingSession: Codable {
    @PartitionKey
    public var hikerId: String
    @SortKey
    public var sessionNumber: Int
}

// MARK: - Hike (composite sk built as `<hikerId>#<season>#<grade>`)

@Table("TrailHikes")
public struct Hike: Codable {
    @PartitionKey
    public var hikeId: String
    @SortKey
    public var hikerSeasonGrade: String
}

// MARK: - TrailRoute (GSI-keyed listing)

@Table("TrailRoutes")
@Index("hikerCreatedAtIndex", partitionKey: "hikerId", sortKey: "createdAt")
@Index("hikerNameIndex", partitionKey: "hikerId", sortKey: "nameLower")
public struct TrailRoute: Codable {
    @PartitionKey
    public var routeId: String
    public var hikerId: String
    public var createdAt: Double
    public var nameLower: String
    public var isFavorite: Bool?
    public var isPrivate: Bool?
    public var tags: Set<String> = []
    public var aliases: [String] = []
    public var lastSeen: Date? = nil
}

// MARK: - MapImport (GSI w/ numeric-sort-key on isArchived)

@Table("TrailMapImports")
@Index("hikerArchivedCreatedAtIndex", partitionKey: "hikerId", sortKey: "isArchived")
public struct MapImport: Codable {
    @PartitionKey
    public var importId: String
    public var hikerId: String
    public var isArchived: Int
    public var createdAt: Double
}

// MARK: - ShareLink (GSI w/ multi-clause key condition)

@Table("TrailShareLinks")
@Index("creatorPublicProfileIndex", partitionKey: "creatorId")
@Index(
    "creatorId-isArchived-isPrivate-isPinned-createdAt-index",
    partitionKeys: ["creatorId", "isArchived", "isPrivate", "isPinned"],
    sortKeys: ["createdAt"]
)
public struct ShareLink: Codable {
    @PartitionKey
    public var linkId: String
    public var creatorId: String
    public var isArchived: Int
    public var isPrivate: Int
    public var isPinned: Int
    public var createdAt: Double
}

// MARK: - PhotoScan (string pk only)

@Table("TrailPhotoScans")
public struct PhotoScan: Codable {
    @PartitionKey
    public var id: String
    public var status: String
    public var updatedAt: Double
    public var reason: String?
}

// MARK: - TrailCard

@Table("TrailCards")
public struct TrailCard: Codable {
    @PartitionKey
    public var cardTokenHash: String
    public var ownerId: String
    public var createdAt: Double
    // Declared as `AWSBase64Data?` rather than `Data?` so it lands as a
    // native `.b` attribute via Soto's Codable bridge. See the Soto adapter
    // for the convention.
    public var signature: AWSBase64Data? = nil
}

// MARK: - HikeEvent (composite-key counter table)

@Table("TrailHikeEvents")
public struct HikeEvent: Codable {
    @PartitionKey
    public var hikerId: String
    @SortKey
    public var eventKey: String
    public var hikeCount: Int
}

// MARK: - DifficultyScore (string pk, optimistic-concurrency target)

@Table("TrailDifficultyScores")
public struct DifficultyScore: Codable {
    @PartitionKey
    public var id: String
    public var score: Double
    public var lastClimbedAt: Double
}

// MARK: - HikerHandle (string pk, condition-on-non-key-attribute target)

@Table("TrailHikerHandles")
public struct HikerHandle: Codable {
    @PartitionKey
    public var handleLower: String
    public var hikerId: String
}

// MARK: - GearLocker (represented column via @ExpressionValue(as:))

public struct GearSlot: Codable, Equatable, Sendable {
    public var label: String
    public var weight: Double
}

/// Consumer-declared representation: the library ships only the
/// `DynamoExpressionRepresentation` seam; encodings for specific types live
/// with the schema that owns them and must match what the model's `Codable`
/// conformance writes on puts.
public enum GearSlotMapEncoder: DynamoExpressionRepresentation {
    public static func encode(_ value: [Int: GearSlot]) throws -> DynamoValue {
        .map(.init(uniqueKeysWithValues: value.map { key, slot in
            (String(key), DynamoValue.map([
                "label": .string(slot.label),
                "weight": .number(String(slot.weight)),
            ]))
        }))
    }
}

@Table("TrailGearLockers")
public struct GearLocker: Codable {
    @PartitionKey
    public var hikerId: String
    // `[Int: GearSlot]` can't be DynamoEncodable (non-string keys, plain
    // Codable value type), so the column declares a representation.
    @ExpressionValue(as: GearSlotMapEncoder.self)
    public var slots: [Int: GearSlot] = [:]
    public var capacity: Int = 0
}

// MARK: - Permit (nested map attribute addressed via document paths)

public struct PermitHold: Codable, Equatable, Sendable {
    public var heldUntil: Double
    public var holdId: String

    public enum CodingKeys: String, CodingKey {
        case heldUntil
        case holdId
    }
}

/// Call-site representation for `set(to:via:)`: `PermitHold` is a plain
/// Codable struct from "another module", so its encoding is supplied ad hoc
/// rather than declared on the model with `@ExpressionValue(as:)`.
public enum PermitHoldEncoder: DynamoExpressionRepresentation {
    public static func encode(_ value: PermitHold) throws -> DynamoValue {
        .map([
            "heldUntil": .number(String(value.heldUntil)),
            "holdId": .string(value.holdId),
        ])
    }
}

@Table("TrailPermits")
public struct Permit: Codable {
    @PartitionKey
    public var permitId: String
    public var hold: PermitHold?
}

// MARK: - PendingHikeBatch (scan target)

@Table("TrailPendingHikeBatches")
public struct PendingHikeBatch: Codable {
    @PartitionKey
    public var batchId: String
    public var attempts: Int
}
