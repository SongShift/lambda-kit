import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

@Suite("CreateTable from model schema")
struct CreateTableInputTests {
    @Test("Multi-attribute GSI lowers to HASH/RANGE elements in declaration order")
    func multiAttributeIndex() throws {
        let input = ShareLink.createTableInput()

        #expect(input.tableName == "TrailShareLinks")
        #expect(input.billingMode == .payPerRequest)
        #expect(input.keySchema?.map(\.attributeName) == ["linkId"])
        #expect(input.keySchema?.map(\.keyType) == [.hash])

        let indexes = try #require(input.globalSecondaryIndexes)
        let wide = try #require(indexes.first {
            $0.indexName == "creatorId-isArchived-isPrivate-isPinned-createdAt-index"
        })
        #expect(wide.keySchema.map(\.attributeName) == [
            "creatorId", "isArchived", "isPrivate", "isPinned", "createdAt",
        ])
        #expect(wide.keySchema.map(\.keyType) == [.hash, .hash, .hash, .hash, .range])
        #expect(wide.projection.projectionType == .all)
    }

    @Test("Key attributes union across table and indexes, deduplicated, with scalar types")
    func attributeDefinitions() throws {
        let input = ShareLink.createTableInput()

        // creatorId keys both GSIs but must appear once.
        let definitions = Dictionary(
            uniqueKeysWithValues: (input.attributeDefinitions ?? []).map {
                ($0.attributeName, $0.attributeType)
            }
        )
        #expect(definitions == [
            "linkId": .s,
            "creatorId": .s,
            "isArchived": .n,
            "isPrivate": .n,
            "isPinned": .n,
            "createdAt": .n,
        ])
    }

    @Test("Composite-key table without indexes emits no GSI block")
    func compositeKeyTable() {
        let input = HikingSession.createTableInput()

        #expect(input.keySchema?.map(\.attributeName) == ["hikerId", "sessionNumber"])
        #expect(input.keySchema?.map(\.keyType) == [.hash, .range])
        #expect(input.globalSecondaryIndexes == nil)
        #expect(input.attributeDefinitions?.map(\.attributeType).sorted { $0.rawValue < $1.rawValue } == [.n, .s])
    }

    @Test("tableName override replaces the wire name")
    func tableNameOverride() {
        let input = ShareLink.createTableInput(tableName: "TrailShareLinks-test-42")
        #expect(input.tableName == "TrailShareLinks-test-42")
    }
}
