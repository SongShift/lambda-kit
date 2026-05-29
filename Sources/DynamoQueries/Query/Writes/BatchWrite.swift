/// A multi-item write against a single table — up to 25 items (puts +
/// deletes combined) per DynamoDB request, 16MB total. Adapters retry the
/// `UnprocessedItems` portion of every response until empty.
///
/// `Model` is the row shape. Puts carry `Model` instances; deletes carry
/// pre-encoded primary-key maps (built by `.delete(partitionKey:)` /
/// `.delete(partitionKey:sortKey:)`).
///
/// Like `BatchGetInput`, this is a single-table operation. DynamoDB
/// `BatchWriteItem` natively supports multi-table writes, but the typed-DSL
/// surface for that lives more naturally on a transaction-style API.
public struct BatchWriteInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public var putItems: [Model]
    public var deleteKeys: [[String: DynamoValue]]

    public init(
        tableName: String,
        putItems: [Model] = [],
        deleteKeys: [[String: DynamoValue]] = []
    ) {
        self.tableName = tableName
        self.putItems = putItems
        self.deleteKeys = deleteKeys
    }
}

// MARK: - Modifiers

extension BatchWriteInput {
    public func put(_ item: Model) -> Self {
        var copy = self
        copy.putItems.append(item)
        return copy
    }

    public func put(contentsOf items: [Model]) -> Self {
        var copy = self
        copy.putItems.append(contentsOf: items)
        return copy
    }

    public func delete(partitionKey: some DynamoEncodable) throws -> Self {
        guard Model._table.sortKey == nil else {
            throw PrimaryKeyError.sortKeyRequired(table: Model._table.name)
        }
        var copy = self
        copy.deleteKeys.append([
            Model._table.partitionKey: partitionKey.toDynamoValue()
        ])
        return copy
    }

    public func delete(
        partitionKey: some DynamoEncodable,
        sortKey: some DynamoEncodable
    ) throws -> Self {
        guard let sortKeyName = Model._table.sortKey else {
            throw PrimaryKeyError.unexpectedSortKey(table: Model._table.name)
        }
        var copy = self
        copy.deleteKeys.append([
            Model._table.partitionKey: partitionKey.toDynamoValue(),
            sortKeyName: sortKey.toDynamoValue(),
        ])
        return copy
    }
}

// MARK: - Execute

extension BatchWriteInput {
    public func execute(using client: any DynamoClient) async throws {
        try await client.batchWrite(self)
    }
}

// MARK: - Builder

extension DynamoModel {
    /// Start a batch write against this table. Chain `.put(_:)` and
    /// `.delete(...)` to add operations, then `.execute(using:)`.
    public static func batchWrite() -> BatchWriteInput<Self> {
        BatchWriteInput(tableName: _table.name)
    }
}
