//
//  Models.swift
//
//  DynamoDB tables for the TrailLog demo. Schema chosen to exercise the
//  most common access patterns: partition-key-only, composite key, and a GSI.
//

import DynamoQueries
import Foundation

/// A user-facing record of a completed hike.
@Table("Hikes")
@Index("hikerCompletedAtIndex", partitionKey: "hikerId", sortKey: "completedAt")
struct Hike: Codable, Sendable {
    @PartitionKey var hikeId: String
    var hikerId: String
    var trailName: String
    var completedAt: Double
    var distanceMiles: Double
    var elevationGainFeet: Int
    var rating: Int
    var notes: String?
    var tags: Set<String> = []
}

/// A composite-key counter table used for "how many hikes per hiker per
/// day?" rollups.
@Table("HikeCounts")
struct HikeCount: Codable, Sendable {
    @PartitionKey var hikerId: String
    @SortKey var dayKey: String
    var count: Int
}

/// A partition-key-only handle reservation, the canonical insert-if-not-exists
/// target.
@Table("HikerHandles")
struct HikerHandle: Codable, Sendable {
    @PartitionKey var handleLower: String
    var hikerId: String
    var reservedAt: Double
}
