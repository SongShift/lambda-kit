import SwiftSyntax
import SwiftSyntaxMacros

/// Marks a property as the partition key. Generates no code. Read by @Table.
public struct PartitionKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Marks a property as the sort key. Generates no code. Read by @Table.
public struct SortKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Overrides the DynamoDB attribute name for a property. Generates no code. Read by @Table.
public struct AttributeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Declares a secondary index on a `@Table` struct. Generates no peers. Read
/// by `@Table`, which collects sibling `@Index` annotations and emits a typed
/// `Indexes` enum with one `static let` per declared index.
public struct IndexMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
