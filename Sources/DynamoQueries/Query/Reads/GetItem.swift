import Logging

/// A single-item lookup keyed by primary key, parameterized by the model it
/// returns.
///
/// `GetItem` is the right operation when the caller has the exact primary key
/// of the item they want. For range scans across a partition (or filtered
/// queries) reach for `Query` instead.
public struct GetItemInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public let key: [String: DynamoValue]
    public var consistentRead: Bool
    public var projectionAttributes: [String]?

    public init(
        tableName: String,
        key: [String: DynamoValue],
        consistentRead: Bool = false,
        projectionAttributes: [String]? = nil
    ) {
        self.tableName = tableName
        self.key = key
        self.consistentRead = consistentRead
        self.projectionAttributes = projectionAttributes
    }
}

// MARK: - Modifiers

extension GetItemInput {
    /// Strongly consistent read. Default is eventually consistent; flipping
    /// this on doubles read-capacity cost.
    public func consistentRead(_ value: Bool = true) -> Self {
        var copy = self
        copy.consistentRead = value
        return copy
    }

    /// Restrict the response to the listed attributes. Same caveats as
    /// `QueryInput.project`.
    public func project(_ attrs: any AttributeReference...) -> Self {
        project(attrs)
    }

    public func project(_ attrs: [any AttributeReference]) -> Self {
        var copy = self
        copy.projectionAttributes = attrs.map(\.name)
        return copy
    }
}

// MARK: - Execute

extension GetItemInput {
    public func execute(
        using client: any DynamoClient,
        logger: Logger = .dynamoQueriesDisabled
    ) async throws -> Model? {
        try await client.getItem(self, logger: logger)
    }
}

// MARK: - Errors

/// Raised when the partition/sort key arity passed to a key-addressed
/// operation (`get`, `update`, `delete`) doesn't match the table's declared
/// key schema.
///
/// This is a runtime check rather than a compile-time one because the
/// primary-key shape lives on `TableMetadata` (a runtime value), not in the
/// type. A future macro pass could lift this into the type system; until then,
/// a misuse throws here rather than silently producing a malformed
/// DynamoDB request.
public enum PrimaryKeyError: Error, Sendable, Equatable {
    /// Caller used the partition-key-only overload, but the table declares a sort key.
    case sortKeyRequired(table: String)

    /// Caller supplied a sort key, but the table doesn't declare one.
    case unexpectedSortKey(table: String)
}
