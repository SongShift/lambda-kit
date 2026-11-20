import DynamoQueries
@testable import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// How a model's `Set` columns cross the Codable bridge. `SotoSetEncodingTests`
// is the wire-level counterpart: it checks the requests `SotoDynamoClient`
// sends.

@Suite("DynamoCoder sets")
struct DynamoSetCoderTests {

    private let profile = HikerProfile(
        hikerId: "hiker-1",
        badges: ["first-summit", "night-hike"],
        summitYears: [2023, 2024],
        paces: [4.5, 5.25],
        wishlist: ["long-trail"],
        fingerprints: [Data([0x01, 0x02])],
        gear: GearList(name: "alpine", items: ["rope", "stove"])
    )

    @Test("Set columns are written as sets, in a stable element order, and round-trip")
    func roundTrip() throws {
        let item = try profile.put().toSotoPutItemInput().item

        #expect(item["badges"] == .ss(["first-summit", "night-hike"]))
        #expect(item["summitYears"] == .ns(["2023", "2024"]))
        #expect(item["paces"] == .ns(["4.5", "5.25"]))
        #expect(item["wish_list"] == .ss(["long-trail"]))
        #expect(try DynamoDecoder.decode(HikerProfile.self, from: item) == profile)
    }

    @Test("An item stored with lists still decodes into sets")
    func decodesListShapedItem() throws {
        // The shape every whole-item write produced before set columns were
        // converted.
        let stored: [String: DynamoDB.AttributeValue] = [
            "hikerId": .s("hiker-1"),
            "badges": .l([.s("first-summit"), .s("night-hike")]),
            "summitYears": .l([.n("2023"), .n("2024")]),
            "paces": .l([.n("4.5"), .n("5.25")]),
            "wish_list": .l([.s("long-trail")]),
            "fingerprints": .l([.l([.n("1"), .n("2")])]),
            "gear": .m(["name": .s("alpine"), "items": .l([.s("rope"), .s("stove")])]),
        ]

        #expect(try DynamoDecoder.decode(HikerProfile.self, from: stored) == profile)
    }

    @Test("An empty optional set reads back as nil, an empty non-optional set as empty")
    func emptySetsReadBack() throws {
        let empty = HikerProfile(hikerId: "hiker-1", badges: [], summitYears: [], paces: [], wishlist: [])
        let item = try empty.put().toSotoPutItemInput().item

        // DynamoDB has no empty set, and an absent attribute is also what it
        // leaves behind when the last element is removed from one.
        var readBack = empty
        readBack.paces = nil
        readBack.wishlist = nil
        #expect(try DynamoDecoder.decode(HikerProfile.self, from: item) == readBack)
    }

    @Test("Set<Data> keeps its list encoding — binary sets are not covered")
    func binarySetStaysList() throws {
        // Pinned as documentation: the decoder cannot read a `BS` attribute
        // back into `Data` elements (plain `Data` has the same limitation, see
        // `plainDataFallback`), so writing one would break the round trip.
        let item = try profile.put().toSotoPutItemInput().item

        #expect(item["fingerprints"] == .l([.l([.n("1"), .n("2")])]))
    }
}
