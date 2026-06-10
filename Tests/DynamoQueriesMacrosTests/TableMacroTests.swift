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
                static let _table = TableMetadata(name: "Users", partitionKey: "id", sortKey: nil)

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
                    static let byEmailIndex = Index<User>(name: "byEmail-index", partitionKey: "email", sortKey: nil)
                }

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
