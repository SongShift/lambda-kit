import DynamoQueries
@testable import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// Round-trip tests for the direct bridge between Codable and DynamoDB.AttributeValue.
// These cover the cases that the existing equivalence suites don't.
// `Equivalence.swift` deliberately skips item-body comparison because the
// previous JSONEncoder path produced wire-format noise (e.g. `1.0` vs `1`)
// that wasn't worth pinning down.

@Suite("DynamoCoder round-trip")
struct DynamoCoderTests {

    @Test("Primitives round-trip through encode/decode")
    func primitives() throws {
        struct Row: Codable, Equatable {
            let id: String
            let count: Int
            let ratio: Double
            let active: Bool
        }
        let value = Row(id: "abc", count: 42, ratio: 1.5, active: true)
        let item = try DynamoEncoder.encode(value)

        #expect(item["id"] == .s("abc"))
        #expect(item["count"] == .n("42"))
        #expect(item["active"] == .bool(true))
        if case .n(let raw) = item["ratio"] {
            #expect(Double(raw) == 1.5)
        } else {
            Issue.record("ratio should be a number, was \(String(describing: item["ratio"]))")
        }

        let restored = try DynamoDecoder.decode(Row.self, from: item)
        #expect(restored == value)
    }

    @Test("Optional present and absent")
    func optionalRoundTrip() throws {
        struct Row: Codable, Equatable {
            let id: String
            let nickname: String?
        }
        let withName = Row(id: "1", nickname: "Ada")
        let withoutName = Row(id: "2", nickname: nil)

        let withItem = try DynamoEncoder.encode(withName)
        let withoutItem = try DynamoEncoder.encode(withoutName)

        #expect(withItem["nickname"] == .s("Ada"))
        // `encodeIfPresent` (the Codable-synthesized path) skips nil entirely:
        // the key should not be in the encoded item.
        #expect(withoutItem["nickname"] == nil)

        #expect(try DynamoDecoder.decode(Row.self, from: withItem) == withName)
        #expect(try DynamoDecoder.decode(Row.self, from: withoutItem) == withoutName)
    }

    @Test("Arrays and sets become DynamoDB lists")
    func collectionsRoundTrip() throws {
        struct Row: Codable, Equatable {
            let aliases: [String]
            let tags: Set<String>
        }
        let value = Row(aliases: ["one", "two"], tags: ["red", "blue"])
        let item = try DynamoEncoder.encode(value)

        guard case .l(let aliasList) = item["aliases"] else {
            Issue.record("aliases should encode as list")
            return
        }
        #expect(aliasList == [.s("one"), .s("two")])
        // Sets go through the unkeyed-container path, so they land as `.l`.
        // (Native `.ss` is reserved for the manual `DynamoEncodable` DSL.)
        guard case .l = item["tags"] else {
            Issue.record("tags should encode as list, got \(String(describing: item["tags"]))")
            return
        }

        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("AWSBase64Data encodes as native DynamoDB binary")
    func awsBase64DataRoundTrip() throws {
        // The recommended type for binary fields. Soto's coder special-cases
        // `AWSBase64Data` and writes it as a native `.b` attribute.
        struct Row: Codable, Equatable {
            let id: String
            let payload: AWSBase64Data
        }
        let bytes = Data([0xde, 0xad, 0xbe, 0xef])
        let value = Row(id: "row", payload: .data(bytes))
        let item = try DynamoEncoder.encode(value)

        guard case .b(let blob) = item["payload"] else {
            Issue.record("payload should encode as `.b`, got \(String(describing: item["payload"]))")
            return
        }
        #expect(Data(blob.decoded() ?? []) == bytes)

        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("Plain Data falls through to a chunky byte-list — prefer AWSBase64Data")
    func plainDataFallback() throws {
        // Pinned as documentation: Soto's coder doesn't special-case `Data`,
        // so a `Data` field encodes as `.l([.n("…")])`, round-trip works,
        // but the wire is ~4× the size of native `.b`. New models should use
        // `AWSBase64Data` (see `awsBase64DataRoundTrip`).
        struct Row: Codable, Equatable {
            let id: String
            let payload: Data
        }
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let value = Row(id: "row", payload: payload)
        let item = try DynamoEncoder.encode(value)

        guard case .l(let listed) = item["payload"] else {
            Issue.record("payload encodes as a list under Soto's default Data path")
            return
        }
        #expect(listed == [.n("222"), .n("173"), .n("190"), .n("239")])

        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("Nested struct encodes as a map attribute")
    func nestedStruct() throws {
        struct Inner: Codable, Equatable { let label: String }
        struct Row: Codable, Equatable {
            let id: String
            let inner: Inner
        }
        let value = Row(id: "1", inner: Inner(label: "nested"))
        let item = try DynamoEncoder.encode(value)

        guard case .m(let inner) = item["inner"] else {
            Issue.record("inner should encode as map")
            return
        }
        #expect(inner["label"] == .s("nested"))

        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("Date encodes as Unix epoch seconds")
    func dateRoundTrip() throws {
        struct Row: Codable, Equatable {
            let id: String
            let stamp: Date
        }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000.5)
        let value = Row(id: "1", stamp: stamp)
        let item = try DynamoEncoder.encode(value)

        // Matches the manual `DynamoEncodable` extension on `Date`. Both
        // paths now write epoch seconds, so a value written via
        // `Attribute<Date>.set(...)` round-trips through Codable cleanly.
        guard case .n(let raw) = item["stamp"] else {
            Issue.record("stamp should encode as number")
            return
        }
        #expect(Double(raw) == 1_700_000_000.5)

        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("Explicit null round-trips as DynamoDB NULL")
    func explicitNull() throws {
        struct Row: Codable, Equatable {
            let id: String
            var nickname: String? = nil
            enum CodingKeys: String, CodingKey { case id, nickname }
            init(id: String, nickname: String?) {
                self.id = id
                self.nickname = nickname
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.id = try c.decode(String.self, forKey: .id)
                self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                // Force-write nil so we exercise the encodeNil path rather
                // than encodeIfPresent's "skip nil" behavior.
                if nickname == nil {
                    try c.encodeNil(forKey: .nickname)
                } else {
                    try c.encode(nickname, forKey: .nickname)
                }
            }
        }
        let value = Row(id: "1", nickname: nil)
        let item = try DynamoEncoder.encode(value)

        #expect(item["nickname"] == .null(true))
        #expect(try DynamoDecoder.decode(Row.self, from: item) == value)
    }

    @Test("Trailing tags model from the test suite round-trips")
    func trailRouteRoundTrip() throws {
        // Mirrors `TrailRoute` in Tests/.../Models/TrailLog.swift, which
        // exercises the full type spread (Optional<Bool>, Set<String>,
        // [String], Optional<Date>) the demo apps use.
        struct TrailRoute: Codable, Equatable {
            let routeId: String
            let hikerId: String
            let createdAt: Double
            let nameLower: String
            let isFavorite: Bool?
            let isPrivate: Bool?
            let tags: Set<String>
            let aliases: [String]
            let lastSeen: Date?
        }
        let value = TrailRoute(
            routeId: "r-1",
            hikerId: "h-1",
            createdAt: 1700000000.5,
            nameLower: "south summit",
            isFavorite: true,
            isPrivate: nil,
            tags: ["alpine", "exposed"],
            aliases: ["S Summit"],
            lastSeen: Date(timeIntervalSinceReferenceDate: 5_000)
        )
        let item = try DynamoEncoder.encode(value)
        #expect(item["isPrivate"] == nil)
        #expect(try DynamoDecoder.decode(TrailRoute.self, from: item) == value)
    }
}
