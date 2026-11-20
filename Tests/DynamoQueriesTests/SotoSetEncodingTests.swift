import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// Every write that sends a whole model item, checked on the wire: the JSON
// body `SotoDynamoClient` hands to the HTTP client is decoded back into
// `DynamoValue`s, so these assertions see the attribute types DynamoDB would.

/// The three operations that send a whole item.
enum ItemWrite: String, CaseIterable, Sendable {
    case put
    case batchWrite
    case transactPut
}

private struct PutItemBody: Decodable {
    let item: [String: DynamoValue]

    enum CodingKeys: String, CodingKey {
        case item = "Item"
    }
}

private struct BatchWriteBody: Decodable {
    struct WriteRequest: Decodable {
        let putRequest: PutItemBody

        enum CodingKeys: String, CodingKey {
            case putRequest = "PutRequest"
        }
    }

    let requestItems: [String: [WriteRequest]]

    enum CodingKeys: String, CodingKey {
        case requestItems = "RequestItems"
    }
}

private struct TransactWriteBody: Decodable {
    struct TransactItem: Decodable {
        let put: PutItemBody

        enum CodingKeys: String, CodingKey {
            case put = "Put"
        }
    }

    let transactItems: [TransactItem]

    enum CodingKeys: String, CodingKey {
        case transactItems = "TransactItems"
    }
}

private struct UpdateItemBody: Decodable {
    let expressionAttributeValues: [String: DynamoValue]

    enum CodingKeys: String, CodingKey {
        case expressionAttributeValues = "ExpressionAttributeValues"
    }
}

/// Sends `profile` through `write` and returns the item found in the request.
private func itemSent(
    for profile: HikerProfile,
    by write: ItemWrite
) async throws -> [String: DynamoValue] {
    let http = CapturingHTTPClient()
    try await withSotoClient(sendingTo: http) { client in
        switch write {
        case .put:
            try await profile.put().execute(using: client)
        case .batchWrite:
            try await HikerProfile.batchWrite().put(profile).execute(using: client)
        case .transactPut:
            try await TransactWriteInput { profile.put() }.execute(using: client)
        }
    }
    switch write {
    case .put:
        let bodies = try await http.requests(as: PutItemBody.self)
        return try #require(bodies.first).item
    case .batchWrite:
        let bodies = try await http.requests(as: BatchWriteBody.self)
        let requests = try #require(bodies.first?.requestItems["TrailHikerProfiles"])
        return try #require(requests.first).putRequest.item
    case .transactPut:
        let bodies = try await http.requests(as: TransactWriteBody.self)
        return try #require(bodies.first?.transactItems.first).put.item
    }
}

@Suite("Soto set encoding on the wire")
struct SotoSetEncodingTests {

    @Test("Set columns are sent as SS and NS", arguments: ItemWrite.allCases)
    func setColumns(write: ItemWrite) async throws {
        let profile = HikerProfile(
            hikerId: "hiker-1",
            badges: ["first-summit", "night-hike"],
            summitYears: [2023, 2024],
            paces: [4.5, 5.25],
            wishlist: ["long-trail"]
        )

        let item = try await itemSent(for: profile, by: write)

        // `wishlist` is renamed with `@Attribute`, so it is found under the
        // name the query DSL uses for it.
        #expect(item == [
            "hikerId": .string("hiker-1"),
            "badges": .stringSet(["first-summit", "night-hike"]),
            "summitYears": .numberSet(["2023", "2024"]),
            "paces": .numberSet(["4.5", "5.25"]),
            "wish_list": .stringSet(["long-trail"]),
        ])
    }

    @Test("put and addToSet agree on the attribute type")
    func putAgreesWithAddToSet() async throws {
        let profile = HikerProfile(hikerId: "hiker-1", badges: ["first-summit"], summitYears: [2024])
        let http = CapturingHTTPClient()
        try await withSotoClient(sendingTo: http) { client in
            try await HikerProfile.update(partitionKey: "hiker-1") { column in
                column.badges.addToSet(["night-hike"])
                column.summitYears.removeFromSet([2024])
            }.execute(using: client)
        }
        let update = try #require(try await http.requests(as: UpdateItemBody.self).first)
        let operands = Array(update.expressionAttributeValues.values)

        let item = try await itemSent(for: profile, by: .put)

        // `ADD` and `DELETE` only apply to an attribute stored as the same
        // set type as their operand.
        #expect(operands.contains(.stringSet(["night-hike"])))
        #expect(item["badges"] == .stringSet(["first-summit"]))
        #expect(operands.contains(.numberSet(["2024"])))
        #expect(item["summitYears"] == .numberSet(["2024"]))
    }

    @Test("A nil optional set is not sent", arguments: ItemWrite.allCases)
    func nilOptionalSet(write: ItemWrite) async throws {
        let profile = HikerProfile(
            hikerId: "hiker-1",
            badges: ["first-summit"],
            summitYears: [2024],
            paces: nil,
            wishlist: nil
        )

        let item = try await itemSent(for: profile, by: write)

        #expect(item == [
            "hikerId": .string("hiker-1"),
            "badges": .stringSet(["first-summit"]),
            "summitYears": .numberSet(["2024"]),
        ])
    }

    @Test(
        "An empty set is never sent as a set: left out when optional, an empty list otherwise",
        arguments: ItemWrite.allCases
    )
    func emptySets(write: ItemWrite) async throws {
        let profile = HikerProfile(hikerId: "hiker-1", badges: [], summitYears: [], paces: [], wishlist: [])

        let item = try await itemSent(for: profile, by: write)

        #expect(item == [
            "hikerId": .string("hiker-1"),
            "badges": .list([]),
            "summitYears": .list([]),
        ])
    }

    @Test("A set nested in another value is sent as a list", arguments: ItemWrite.allCases)
    func nestedSetStaysList(write: ItemWrite) async throws {
        // Pinned as documentation: only the model's own columns are converted.
        let profile = HikerProfile(
            hikerId: "hiker-1",
            badges: ["first-summit"],
            gear: GearList(name: "alpine", items: ["rope"])
        )

        let item = try await itemSent(for: profile, by: write)

        #expect(item["badges"] == .stringSet(["first-summit"]))
        #expect(item["gear"] == .map(["name": .string("alpine"), "items": .list([.string("rope")])]))
    }
}
