/// A targeted update against an existing item, identified by its primary
/// key. Unlike `PutItem`, `UpdateItem` modifies only the attributes named in
/// the update expression; everything else on the item is left alone.
///
/// `conditionExpression`, when non-nil, is checked atomically with the
/// update — DynamoDB applies the update iff the condition holds. The
/// canonical use is optimistic concurrency (`SET version = version + 1
/// WHERE version = :expected`).
///
/// The `Model` phantom type carries the table's schema so a conditional
/// failure can decode the prior item into `ConditionalCheckFailed<Model>`.
public struct UpdateInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public let key: [String: DynamoValue]
    public let updateExpression: String
    public let conditionExpression: String?
    public let expressionAttributeNames: [String: String]
    public let expressionAttributeValues: [String: DynamoValue]
    public var returnPriorOnConflict: Bool

    public init(
        tableName: String,
        key: [String: DynamoValue],
        updateExpression: String,
        conditionExpression: String? = nil,
        expressionAttributeNames: [String: String],
        expressionAttributeValues: [String: DynamoValue],
        returnPriorOnConflict: Bool = false
    ) {
        self.tableName = tableName
        self.key = key
        self.updateExpression = updateExpression
        self.conditionExpression = conditionExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
        self.returnPriorOnConflict = returnPriorOnConflict
    }
}

// MARK: - Modifiers

extension UpdateInput {
    /// On a conditional-check failure, ask DynamoDB to return the prior item
    /// alongside the error. Decoded item lands on
    /// `ConditionalCheckFailed.priorItem`. Costs an extra read on the
    /// failure path; off by default.
    public func returnConflictingItem(_ value: Bool = true) -> Self {
        var copy = self
        copy.returnPriorOnConflict = value
        return copy
    }

    /// Ask DynamoDB to return the entire item *after* the update is applied.
    /// `.execute(using:)` then returns `Model?` instead of `Void`.
    public func returnNewValues() -> UpdateReturning<Model> {
        UpdateReturning(input: self, returnValues: .allNew)
    }

    /// Ask DynamoDB to return the entire item *before* the update was
    /// applied. `Model?` is the pre-update item.
    public func returnOldValues() -> UpdateReturning<Model> {
        UpdateReturning(input: self, returnValues: .allOld)
    }

    /// Ask DynamoDB to return only the attributes touched by the update,
    /// in their post-update state. The decoded `Model` may be missing
    /// fields that weren't touched — model only-this-update fields as
    /// optional, or the decode will fail.
    public func returnUpdatedNewValues() -> UpdateReturning<Model> {
        UpdateReturning(input: self, returnValues: .updatedNew)
    }

    /// Like `returnUpdatedNewValues()` but pre-update values. Same caveat
    /// about the model needing optional fields applies.
    public func returnUpdatedOldValues() -> UpdateReturning<Model> {
        UpdateReturning(input: self, returnValues: .updatedOld)
    }
}

// MARK: - Return-value enum + wrapper

public enum UpdateReturnValues: Sendable {
    case allNew
    case allOld
    case updatedNew
    case updatedOld
}

/// Wrapper produced by `UpdateInput.returnNewValues()` and friends.
/// `.execute(using:)` returns `Model?` — `nil` means DynamoDB returned no
/// `Attributes` field for the response (which happens for some return-value
/// modes when there's nothing to return).
public struct UpdateReturning<Model: DynamoModel>: Sendable {
    public let input: UpdateInput<Model>
    public let returnValues: UpdateReturnValues

    public init(input: UpdateInput<Model>, returnValues: UpdateReturnValues) {
        self.input = input
        self.returnValues = returnValues
    }

    public func execute(using client: any DynamoClient) async throws -> Model? {
        try await client.updateItemReturning(self)
    }
}

// MARK: - Execute

extension UpdateInput {
    public func execute(using client: any DynamoClient) async throws {
        try await client.updateItem(self)
    }
}

// MARK: - Builder

public enum UpdateInputBuilder {
    public static func build<Model: DynamoModel>(
        for type: Model.Type,
        key: [String: DynamoValue],
        actions: [UpdateAction],
        condition: [Expression] = []
    ) -> UpdateInput<Model> {
        var allocator = PlaceholderAllocator()
        let updateExpression = UpdateExpressionCompiler.compile(actions, allocator: &allocator)
        let conditionExpression = condition.isEmpty
            ? nil
            : ExpressionCompiler.compile(condition, allocator: &allocator)
        return UpdateInput<Model>(
            tableName: Model._table.name,
            key: key,
            updateExpression: updateExpression,
            conditionExpression: conditionExpression,
            expressionAttributeNames: allocator.attributeNames,
            expressionAttributeValues: allocator.attributeValues
        )
    }
}
