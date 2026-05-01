/// An insert-or-replace request for a single item.
///
/// Holding the concrete `Model` value (rather than a pre-encoded
/// `[String: DynamoValue]` map) lets transport adapters choose their own
/// encoding strategy — the Soto adapter, for instance, bridges through
/// `JSONEncoder` so it can encode the full surface of `Codable` (lists, nested
/// maps, dates) that `DynamoValue` doesn't yet model.
///
/// `conditionExpression` is `nil` for unconditional puts and a fully compiled
/// expression string (with placeholders resolved against
/// `expressionAttributeNames` / `expressionAttributeValues`) for conditional
/// puts. The most common condition is `attribute_not_exists(pk)` — i.e. an
/// "insert only if not already present" guard.
public struct PutItemInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public let item: Model
    public let conditionExpression: String?
    public let expressionAttributeNames: [String: String]
    public let expressionAttributeValues: [String: DynamoValue]
    public var returnPriorOnConflict: Bool

    public init(
        tableName: String,
        item: Model,
        conditionExpression: String? = nil,
        expressionAttributeNames: [String: String] = [:],
        expressionAttributeValues: [String: DynamoValue] = [:],
        returnPriorOnConflict: Bool = false
    ) {
        self.tableName = tableName
        self.item = item
        self.conditionExpression = conditionExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
        self.returnPriorOnConflict = returnPriorOnConflict
    }
}

// MARK: - Modifiers

extension PutItemInput {
    /// On a conditional-check failure, ask DynamoDB to return the prior item
    /// alongside the error. Same caveats as `UpdateInput.returnConflictingItem`.
    public func returnConflictingItem(_ value: Bool = true) -> Self {
        var copy = self
        copy.returnPriorOnConflict = value
        return copy
    }
}

// MARK: - Execute

extension PutItemInput {
    public func execute(using client: any DynamoClient) async throws {
        try await client.putItem(self)
    }
}

// MARK: - Builder

public enum PutItemInputBuilder {
    public static func build<Model: DynamoModel>(
        item: Model,
        condition: [Expression] = []
    ) -> PutItemInput<Model> {
        var allocator = PlaceholderAllocator()
        let conditionExpression = condition.isEmpty
            ? nil
            : ExpressionCompiler.compile(condition, allocator: &allocator)
        return PutItemInput(
            tableName: Model._table.name,
            item: item,
            conditionExpression: conditionExpression,
            expressionAttributeNames: allocator.attributeNames,
            expressionAttributeValues: allocator.attributeValues
        )
    }
}
