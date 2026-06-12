import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import DynamoQueriesMacros

private let testMacros: [String: Macro.Type] = [
    "Table": TableMacro.self,
    "Index": IndexMacro.self,
    "PartitionKey": PartitionKeyMacro.self,
    "SortKey": SortKeyMacro.self,
    "Attribute": AttributeMacro.self,
    "ExpressionValue": ExpressionValueMacro.self,
]

final class TableMacroTests: XCTestCase {

    func testHyphenatedIndexNameCamelCasesIdentifier() {
        assertMacroExpansion(
            """
            @Table("Users")
            @Index("byEmail-index", partitionKey: "email")
            struct User {
                @PartitionKey var id: String
                var email: String
            }
            """,
            expandedSource: """
            struct User {
                var id: String
                var email: String
            }

            extension User: DynamoModel {
                static let _table = TableMetadata(name: "Users", partitionKey: KeyAttribute("id", type: (String).dynamoKeyType), sortKey: nil)

                enum Attributes {
                    static let id = Attribute<String>("id")
                    static let email = Attribute<String>("email")
                }

                struct Columns: Sendable {
                    let id = Attribute<String>("id")
                    let email = Attribute<String>("email")
                }

                static let columns = Columns()

                enum Indexes {
                    static let byEmailIndex = Index<User>(name: "byEmail-index", partitionKeys: [KeyAttribute("email", type: (String).dynamoKeyType)])
                }

                static let indexes: [Index<User>] = [Indexes.byEmailIndex]

                static func get(partitionKey: some DynamoQueries.DynamoEncodable) -> DynamoQueries.GetItemInput<User> {
                    DynamoQueries.GetItemInput(tableName: _table.name, key: ["id": partitionKey.toDynamoValue()])
                }

                static func update(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.UpdateBuilder _ build: (Columns) throws -> [DynamoQueries.UpdateAction],
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in
                        []
                    }
                ) rethrows -> DynamoQueries.UpdateInput<User> {
                    DynamoQueries.UpdateInputBuilder.build(for: User.self, key: ["id": partitionKey.toDynamoValue()], actions: try build(columns), condition: condition(columns))
                }

                static func delete(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in
                        []
                    }
                ) -> DynamoQueries.DeleteItemInput<User> {
                    DynamoQueries.DeleteItemInputBuilder.build(for: User.self, key: ["id": partitionKey.toDynamoValue()], condition: condition(columns))
                }

                static var $id: Attribute<String> {
                    Attributes.id
                }
                static var $email: Attribute<String> {
                    Attributes.email
                }
            }
            """,
            macros: testMacros
        )
    }

    func testMultiAttributeKeysExpansion() {
        assertMacroExpansion(
            """
            @Table("QuickShareLinks")
            @Index(
                "creatorId-isDeleted-createdAt-index",
                partitionKeys: ["creatorId", "isDeleted"],
                sortKeys: ["createdAt"]
            )
            struct QuickShareLink {
                @PartitionKey var linkId: String
                var creatorId: String
                var isDeleted: Int
                var createdAt: Double
            }
            """,
            expandedSource: """
            struct QuickShareLink {
                var linkId: String
                var creatorId: String
                var isDeleted: Int
                var createdAt: Double
            }

            extension QuickShareLink: DynamoModel {
                static let _table = TableMetadata(name: "QuickShareLinks", partitionKey: KeyAttribute("linkId", type: (String).dynamoKeyType), sortKey: nil)

                enum Attributes {
                    static let linkId = Attribute<String>("linkId")
                    static let creatorId = Attribute<String>("creatorId")
                    static let isDeleted = Attribute<Int>("isDeleted")
                    static let createdAt = Attribute<Double>("createdAt")
                }

                struct Columns: Sendable {
                    let linkId = Attribute<String>("linkId")
                    let creatorId = Attribute<String>("creatorId")
                    let isDeleted = Attribute<Int>("isDeleted")
                    let createdAt = Attribute<Double>("createdAt")
                }

                static let columns = Columns()

                enum Indexes {
                    static let creatorIdIsDeletedCreatedAtIndex = Index<QuickShareLink>(name: "creatorId-isDeleted-createdAt-index", partitionKeys: [KeyAttribute("creatorId", type: (String).dynamoKeyType), KeyAttribute("isDeleted", type: (Int).dynamoKeyType)], sortKeys: [KeyAttribute("createdAt", type: (Double).dynamoKeyType)])
                }

                static let indexes: [Index<QuickShareLink>] = [Indexes.creatorIdIsDeletedCreatedAtIndex]

                static func get(partitionKey: some DynamoQueries.DynamoEncodable) -> DynamoQueries.GetItemInput<QuickShareLink> {
                    DynamoQueries.GetItemInput(tableName: _table.name, key: ["linkId": partitionKey.toDynamoValue()])
                }

                static func update(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.UpdateBuilder _ build: (Columns) throws -> [DynamoQueries.UpdateAction],
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in
                        []
                    }
                ) rethrows -> DynamoQueries.UpdateInput<QuickShareLink> {
                    DynamoQueries.UpdateInputBuilder.build(for: QuickShareLink.self, key: ["linkId": partitionKey.toDynamoValue()], actions: try build(columns), condition: condition(columns))
                }

                static func delete(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in
                        []
                    }
                ) -> DynamoQueries.DeleteItemInput<QuickShareLink> {
                    DynamoQueries.DeleteItemInputBuilder.build(for: QuickShareLink.self, key: ["linkId": partitionKey.toDynamoValue()], condition: condition(columns))
                }

                static var $linkId: Attribute<String> {
                    Attributes.linkId
                }
                static var $creatorId: Attribute<String> {
                    Attributes.creatorId
                }
                static var $isDeleted: Attribute<Int> {
                    Attributes.isDeleted
                }
                static var $createdAt: Attribute<Double> {
                    Attributes.createdAt
                }
            }
            """,
            macros: testMacros
        )
    }

    func testBoolIndexKeyDiagnoses() {
        assertMacroExpansion(
            """
            @Table("Links")
            @Index("byCreator", partitionKeys: ["creatorId", "isDeleted"])
            struct Link {
                @PartitionKey var id: String
                var creatorId: String
                var isDeleted: Bool
            }
            """,
            expandedSource: """
            struct Link {
                var id: String
                var creatorId: String
                var isDeleted: Bool
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Index \"byCreator\" key \"isDeleted\" is Bool, which DynamoDB rejects as a key attribute (keys must be S, N, or B); store the flag as an Int",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }

    func testUnknownIndexKeyDiagnoses() {
        assertMacroExpansion(
            """
            @Table("Links")
            @Index("byCreator", partitionKeys: ["creatorId"], sortKeys: ["missing"])
            struct Link {
                @PartitionKey var id: String
                var creatorId: String
            }
            """,
            expandedSource: """
            struct Link {
                var id: String
                var creatorId: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Index \"byCreator\" references \"missing\", which doesn't match any property's DynamoDB attribute name",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }

    func testTooManyKeyAttributesDiagnoses() {
        assertMacroExpansion(
            """
            @Table("Links")
            @Index("wide", partitionKeys: ["a", "b", "c", "d", "e"])
            struct Link {
                @PartitionKey var id: String
                var a: String
                var b: String
                var c: String
                var d: String
                var e: String
            }
            """,
            expandedSource: """
            struct Link {
                var id: String
                var a: String
                var b: String
                var c: String
                var d: String
                var e: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Index \"wide\" exceeds DynamoDB's limit of 4 partition-key and 4 sort-key attributes",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }

    func testCollidingIndexIdentifiersDiagnose() {
        assertMacroExpansion(
            """
            @Table("Users")
            @Index("byEmail", partitionKey: "email")
            @Index("by-email", partitionKey: "email")
            struct User {
                @PartitionKey var id: String
                var email: String
            }
            """,
            expandedSource: """
            struct User {
                var id: String
                var email: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Index names \"byEmail\" and \"by-email\" both map to the Swift identifier \"byEmail\"",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }
}
