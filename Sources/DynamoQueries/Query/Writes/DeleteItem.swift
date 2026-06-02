import Logging

/// A delete request for a single item, addressed by primary key. Optionally
/// guarded by a condition expression. The delete only fires if the
/// condition holds.
///
/// `Model` is a phantom type used to type-check `ConditionalCheckFailed` on
/// the failure path.
public struct DeleteItemInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public let key: [String: DynamoValue]
    public let conditionExpression: String?
    public let expressionAttributeNames: [String: String]
    public let expressionAttributeValues: [String: DynamoValue]
    public var returnPriorOnConflict: Bool

    public init(
        tableName: String,
        key: [String: DynamoValue],
        conditionExpression: String? = nil,
        expressionAttributeNames: [String: String] = [:],
        expressionAttributeValues: [String: DynamoValue] = [:],
        returnPriorOnConflict: Bool = false
    ) {
        self.tableName = tableName
        self.key = key
        self.conditionExpression = conditionExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
        self.returnPriorOnConflict = returnPriorOnConflict
    }
}

// MARK: - Modifiers

extension DeleteItemInput {
    /// On a conditional-check failure, ask DynamoDB to return the prior item
    /// alongside the error. Same caveats as `UpdateInput.returnConflictingItem`.
    public func returnConflictingItem(_ value: Bool = true) -> Self {
        var copy = self
        copy.returnPriorOnConflict = value
        return copy
    }
}

// MARK: - Execute

extension DeleteItemInput {
    public func execute(
        using client: any DynamoClient,
        logger: Logger = .dynamoQueriesDisabled
    ) async throws {
        try await client.deleteItem(self, logger: logger)
    }
}

// MARK: - Builder

public enum DeleteItemInputBuilder {
    public static func build<Model: DynamoModel>(
        for type: Model.Type,
        key: [String: DynamoValue],
        condition: [Expression] = []
    ) -> DeleteItemInput<Model> {
        var allocator = PlaceholderAllocator()
        let conditionExpression = condition.isEmpty
            ? nil
            : ExpressionCompiler.compile(condition, allocator: &allocator)
        return DeleteItemInput<Model>(
            tableName: Model._table.name,
            key: key,
            conditionExpression: conditionExpression,
            expressionAttributeNames: allocator.attributeNames,
            expressionAttributeValues: allocator.attributeValues
        )
    }
}
