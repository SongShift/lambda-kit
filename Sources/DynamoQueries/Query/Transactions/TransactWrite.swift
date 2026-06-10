import Logging

/// Thrown by `TransactWriteInput.execute(using:)` when DynamoDB cancels the
/// whole transaction. Reports the per-leg cancellation reasons in the same
/// order as the items the user submitted, so `cancellations[i]` describes
/// what happened to the `i`-th item.
///
/// DynamoDB always returns one cancellation entry per leg, even legs that
/// were fine; the "leg succeeded" entries surface here with `reason == nil`,
/// so a typical caller iterates `failedCancellations` rather than
/// `cancellations`. The failing leg's `reason` is a `DynamoFailure` (the
/// same vocabulary used everywhere else) and may carry the conflicting item
/// on `priorRawItem` if the original write asked for it via
/// `.returnConflictingItem()`.
///
/// `priorRawItem` is exposed as a raw `[String: DynamoValue]` map rather
/// than a typed model. A transaction can span tables, so there's no single
/// `Model` that fits every leg. Decode by hand if you need the typed item.
public struct TransactionCanceled: Error, Sendable {
    public let cancellations: [Cancellation]

    public init(cancellations: [Cancellation]) {
        self.cancellations = cancellations
    }

    public struct Cancellation: Sendable {
        /// The leg's position in the original `TransactWriteInput.items`.
        public let index: Int
        /// The categorized failure for this leg, or `nil` if the leg
        /// succeeded. DynamoDB returns an entry for every leg in the
        /// transaction (even ones that didn't fail); we lift the "None"
        /// no-op cancellations to `nil` so callers iterate only real failures.
        public let failure: DynamoFailure?
        /// The raw conflicting item, if `.returnConflictingItem()` was set on
        /// the originating write. The Soto adapter populates this for
        /// `ConditionalCheckFailed` cancellations.
        public let priorRawItem: [String: DynamoValue]?

        public init(
            index: Int,
            failure: DynamoFailure?,
            priorRawItem: [String: DynamoValue]?
        ) {
            self.index = index
            self.failure = failure
            self.priorRawItem = priorRawItem
        }
    }

    /// Only the cancellations whose `failure` is non-nil, i.e., the legs
    /// that actually failed. Skips the "None" entries DynamoDB emits for
    /// succeeded legs.
    public var failedCancellations: [Cancellation] {
        cancellations.filter { $0.failure != nil }
    }
}

extension TransactionCanceled: DynamoError {
    /// Retry the whole transaction only when every recognized failure mode is
    /// retryable. A single non-retryable leg (conditional check, validation,
    /// auth, …) is definitive. The next attempt would fail the same way.
    /// `.unknown` reasons are ignored when deciding retryability so a
    /// future-AWS code can't accidentally flip the decision either way.
    public var isRetryable: Bool {
        var sawRetryable = false
        for failure in cancellations.compactMap(\.failure) {
            if case .unknown = failure.reason { continue }
            if failure.isRetryable {
                sawRetryable = true
            } else {
                return false
            }
        }
        return sawRetryable
    }
}

/// One leg of a `TransactWriteItems` transaction: a Put, Update, Delete, or
/// ConditionCheck. The container is type-erased so a single transaction can
/// span tables/models. The model's typed surface is preserved only for the
/// `put` case (where the adapter needs the original item to encode it).
public struct TransactWriteItem: Sendable {
    public let tableName: String
    public let kind: Kind
    /// Ask DynamoDB to return the conflicting item if this leg fails its
    /// condition check. Surfaces on `TransactionCanceled.Cancellation.priorRawItem`.
    /// Set by `.returnConflictingItem()` on the originating write input.
    public let returnConflictingItem: Bool

    /// The pre-compiled condition portion of a transact item. Mirrors the
    /// shape of conditional expressions on the existing single-item write
    /// inputs.
    public struct Condition: Sendable {
        public let expression: String
        public let attributeNames: [String: String]
        public let attributeValues: [String: DynamoValue]

        public init(
            expression: String,
            attributeNames: [String: String],
            attributeValues: [String: DynamoValue]
        ) {
            self.expression = expression
            self.attributeNames = attributeNames
            self.attributeValues = attributeValues
        }
    }

    public enum Kind: Sendable {
        case put(item: any DynamoModel, condition: Condition?)
        case update(
            key: [String: DynamoValue],
            updateExpression: String,
            condition: Condition?,
            attributeNames: [String: String],
            attributeValues: [String: DynamoValue]
        )
        case delete(key: [String: DynamoValue], condition: Condition?)
        case conditionCheck(key: [String: DynamoValue], condition: Condition)
    }

    public init(tableName: String, kind: Kind, returnConflictingItem: Bool = false) {
        self.tableName = tableName
        self.kind = kind
        self.returnConflictingItem = returnConflictingItem
    }
}

/// A pending transactional write: up to 100 items DynamoDB will apply
/// atomically (all-or-nothing). Build with the `TransactWriteInput { ... }`
/// result-builder init, or hand `init(items:)` a pre-built `[TransactWriteItem]`.
///
/// `ConditionalCheckFailed` is **not** thrown for transactional failures.
/// DynamoDB returns a `TransactionCanceledException` whose cancellation
/// reasons identify which leg failed. Adapters surface that as their native
/// error type for now; a typed wrapper can land later.
public struct TransactWriteInput: Sendable {
    public var items: [TransactWriteItem]

    public init(items: [TransactWriteItem] = []) {
        self.items = items
    }
}

// MARK: - Result-builder init

extension TransactWriteInput {
    /// Build the items list with a closure-style DSL. The closure is
    /// `throws` because the typed builders (`Model.update(...)`,
    /// `Model.delete(...)`, `Model.conditionCheck(...)`) themselves throw on
    /// primary-key arity mismatch. Call sites mark each throwing line with
    /// `try`.
    ///
    ///     try await TransactWriteInput {
    ///         chart.put { ... }
    ///         try MyModel.update(...) { ... } where: { ... }
    ///         try MyModel.delete(...) where: { ... }
    ///         try MyModel.conditionCheck(partitionKey: ...) { ... }
    ///     }
    ///     .execute(using: client)
    public init(@TransactWriteBuilder _ build: () throws -> [TransactWriteItem]) rethrows {
        self.items = try build()
    }
}

// MARK: - TransactWritable

/// A value that can be lowered into one or more `TransactWriteItem` legs.
///
/// Conformers are accepted directly inside a `TransactWriteInput { ... }`
/// result-builder block. The list return lets a single value expand into
/// many legs.
public protocol TransactWritable: Sendable {
    func toTransactWriteItems() -> [TransactWriteItem]
}

extension TransactWriteItem: TransactWritable {
    public func toTransactWriteItems() -> [TransactWriteItem] { [self] }
}

extension TransactWriteInput: TransactWritable {
    public func toTransactWriteItems() -> [TransactWriteItem] { items }
}

extension Array: TransactWritable where Element: TransactWritable {
    public func toTransactWriteItems() -> [TransactWriteItem] {
        flatMap { $0.toTransactWriteItems() }
    }
}

// MARK: - Item conversions

extension PutItemInput: TransactWritable {
    public func toTransactWriteItem() -> TransactWriteItem {
        TransactWriteItem(
            tableName: tableName,
            kind: .put(item: item, condition: transactCondition()),
            returnConflictingItem: returnPriorOnConflict
        )
    }

    public func toTransactWriteItems() -> [TransactWriteItem] { [toTransactWriteItem()] }
}

extension UpdateInput: TransactWritable {
    public func toTransactWriteItem() -> TransactWriteItem {
        TransactWriteItem(
            tableName: tableName,
            kind: .update(
                key: key,
                updateExpression: updateExpression,
                condition: transactCondition(),
                attributeNames: expressionAttributeNames,
                attributeValues: expressionAttributeValues
            ),
            returnConflictingItem: returnPriorOnConflict
        )
    }

    public func toTransactWriteItems() -> [TransactWriteItem] { [toTransactWriteItem()] }
}

extension DeleteItemInput: TransactWritable {
    public func toTransactWriteItem() -> TransactWriteItem {
        TransactWriteItem(
            tableName: tableName,
            kind: .delete(key: key, condition: transactCondition()),
            returnConflictingItem: returnPriorOnConflict
        )
    }

    public func toTransactWriteItems() -> [TransactWriteItem] { [toTransactWriteItem()] }
}

// MARK: - Result builder

@resultBuilder
public enum TransactWriteBuilder {
    public static func buildExpression(
        _ writable: some TransactWritable
    ) -> [TransactWriteItem] {
        writable.toTransactWriteItems()
    }

    public static func buildBlock(_ parts: [TransactWriteItem]...) -> [TransactWriteItem] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [TransactWriteItem]?) -> [TransactWriteItem] {
        part ?? []
    }

    public static func buildEither(first part: [TransactWriteItem]) -> [TransactWriteItem] {
        part
    }

    public static func buildEither(second part: [TransactWriteItem]) -> [TransactWriteItem] {
        part
    }

    public static func buildArray(_ parts: [[TransactWriteItem]]) -> [TransactWriteItem] {
        parts.flatMap { $0 }
    }
}

// MARK: - Execute

extension TransactWriteInput {
    public func execute(
        using client: any DynamoClient,
        logger: Logger = .dynamoQueriesDisabled
    ) async throws {
        try await client.transactWrite(items, logger: logger)
    }
}

// MARK: - ConditionCheck builder

extension DynamoModel {
    /// Build a `ConditionCheck` transact item: checks a row's condition
    /// without writing. Use inside a `TransactWriteInput { ... }` block to
    /// assert state on a related row that this transaction depends on.
    public static func conditionCheck(
        partitionKey: some DynamoEncodable,
        @ConditionBuilder where condition: (Columns) -> [Expression]
    ) throws -> TransactWriteItem {
        guard _table.sortKey == nil else {
            throw PrimaryKeyError.sortKeyRequired(table: _table.name)
        }
        return makeConditionCheck(
            key: [_table.partitionKey: partitionKey.toDynamoValue()],
            expressions: condition(Self.columns)
        )
    }

    public static func conditionCheck(
        partitionKey: some DynamoEncodable,
        sortKey: some DynamoEncodable,
        @ConditionBuilder where condition: (Columns) -> [Expression]
    ) throws -> TransactWriteItem {
        guard let sortKeyName = _table.sortKey else {
            throw PrimaryKeyError.unexpectedSortKey(table: _table.name)
        }
        return makeConditionCheck(
            key: [
                _table.partitionKey: partitionKey.toDynamoValue(),
                sortKeyName: sortKey.toDynamoValue(),
            ],
            expressions: condition(Self.columns)
        )
    }

    private static func makeConditionCheck(
        key: [String: DynamoValue],
        expressions: [Expression]
    ) -> TransactWriteItem {
        var allocator = PlaceholderAllocator()
        let expression = ExpressionCompiler.compile(expressions, allocator: &allocator)
        return TransactWriteItem(
            tableName: _table.name,
            kind: .conditionCheck(
                key: key,
                condition: TransactWriteItem.Condition(
                    expression: expression,
                    attributeNames: allocator.attributeNames,
                    attributeValues: allocator.attributeValues
                )
            )
        )
    }
}

// MARK: - Internal: shared condition extraction

extension PutItemInput {
    fileprivate func transactCondition() -> TransactWriteItem.Condition? {
        guard let expression = conditionExpression else { return nil }
        return TransactWriteItem.Condition(
            expression: expression,
            attributeNames: expressionAttributeNames,
            attributeValues: expressionAttributeValues
        )
    }
}

extension UpdateInput {
    fileprivate func transactCondition() -> TransactWriteItem.Condition? {
        guard let expression = conditionExpression else { return nil }
        return TransactWriteItem.Condition(
            expression: expression,
            attributeNames: expressionAttributeNames,
            attributeValues: expressionAttributeValues
        )
    }
}

extension DeleteItemInput {
    fileprivate func transactCondition() -> TransactWriteItem.Condition? {
        guard let expression = conditionExpression else { return nil }
        return TransactWriteItem.Condition(
            expression: expression,
            attributeNames: expressionAttributeNames,
            attributeValues: expressionAttributeValues
        )
    }
}
