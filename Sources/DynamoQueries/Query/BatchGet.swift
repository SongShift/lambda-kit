/// A multi-key read against a single table. Up to 100 keys per DynamoDB
/// request, 16MB total per response — adapters auto-retry the
/// `UnprocessedKeys` portion of every response until the remainder is empty.
///
/// `Model` is the row shape on the table; the response decodes back into
/// `[Model]` (only items found, missing keys skip silently).
public struct BatchGetInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public let keys: [[String: DynamoValue]]
    public var consistentRead: Bool
    public var projectionAttributes: [String]?

    public init(
        tableName: String,
        keys: [[String: DynamoValue]],
        consistentRead: Bool = false,
        projectionAttributes: [String]? = nil
    ) {
        self.tableName = tableName
        self.keys = keys
        self.consistentRead = consistentRead
        self.projectionAttributes = projectionAttributes
    }
}

// MARK: - Modifiers

extension BatchGetInput {
    public func consistentRead(_ value: Bool = true) -> Self {
        var copy = self
        copy.consistentRead = value
        return copy
    }

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

extension BatchGetInput {
    /// Run the batch get. Returns the decoded items found, in no guaranteed
    /// order (DynamoDB doesn't promise response ordering for batch reads).
    public func execute(using client: any DynamoClient) async throws -> [Model] {
        try await client.batchGet(self)
    }
}

// MARK: - Builder

extension DynamoModel {
    /// Build a `BatchGetInput` for a partition-key-only table. Throws
    /// `PrimaryKeyError.sortKeyRequired` if the table has a sort key — use
    /// the composite-key overload in that case.
    public static func batchGet(
        partitionKeys: [some DynamoEncodable]
    ) throws -> BatchGetInput<Self> {
        guard _table.sortKey == nil else {
            throw PrimaryKeyError.sortKeyRequired(table: _table.name)
        }
        let keys = partitionKeys.map {
            [_table.partitionKey: $0.toDynamoValue()]
        }
        return BatchGetInput(tableName: _table.name, keys: keys)
    }

    /// Build a `BatchGetInput` for a composite-key table. Throws
    /// `PrimaryKeyError.unexpectedSortKey` if the table doesn't declare a
    /// sort key.
    public static func batchGet<P: DynamoEncodable, S: DynamoEncodable>(
        keys: [(partitionKey: P, sortKey: S)]
    ) throws -> BatchGetInput<Self> {
        guard let sortKeyName = _table.sortKey else {
            throw PrimaryKeyError.unexpectedSortKey(table: _table.name)
        }
        let keyMaps = keys.map { entry in
            [
                _table.partitionKey: entry.partitionKey.toDynamoValue(),
                sortKeyName: entry.sortKey.toDynamoValue(),
            ]
        }
        return BatchGetInput(tableName: _table.name, keys: keyMaps)
    }
}
