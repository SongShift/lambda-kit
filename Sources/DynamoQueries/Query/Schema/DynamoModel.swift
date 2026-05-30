public protocol DynamoModel: Sendable, Codable {
    static var _table: TableMetadata { get }

    /// A struct of typed `Attribute<T>` instances (one per declared
    /// property) passed into `query`/`scan`/`update`/etc. closures so call
    /// sites can write `column.observerId` instead of `Model.$observerId`.
    /// The `@Table` macro generates this type alongside the table metadata.
    associatedtype Columns: Sendable
    static var columns: Columns { get }
}

// MARK: - Build entry points

extension DynamoModel {
    /// Build a `QueryInput`. The closure receives a `Columns` proxy bound
    /// to `Self.columns`, so call sites can write `column.observerId`
    /// instead of `Self.$observerId`. Operators DynamoDB rejects in a key
    /// condition (`contains`, `!=`, existence checks, `&&` / `||` / `!`)
    /// produce `Expression` rather than `KeyCondition`, so they fail to
    /// compile inside `Key { ... }` while still working in `Filter { ... }`.
    ///
    /// Add modifiers (`.usingIndex(_:)`, `.limit(_:)`, `.consistentRead()`,
    /// `.scanIndexForward(_:)`, `.startToken(_:)`) and finish with
    /// `.execute(using:)` or `.executeAll(using:)`.
    public static func query(
        @QueryBuilder _ build: (Columns) -> QueryParts
    ) -> QueryInput<Self> {
        let parts = build(Self.columns)
        return QueryInputBuilder.build(
            for: Self.self,
            keyConditions: parts.keyConditions,
            filterConditions: parts.filterConditions
        )
    }

    /// Build a `ScanInput`. The closure receives a `Columns` proxy. Add
    /// modifiers and finish with `.execute(using:)` or `.executeAll(using:)`.
    /// Scans bill for every item read, not every item returned. Prefer
    /// `query` whenever the access pattern lets you constrain the partition
    /// key.
    public static func scan(
        @FilterBuilder _ filter: (Columns) -> [Expression] = { _ in [] }
    ) -> ScanInput<Self> {
        ScanInputBuilder.build(for: Self.self, filterConditions: filter(Self.columns))
    }

    /// Build a `PutItemInput` for this item. Without a `where:` block the put
    /// replaces any existing item with the same primary key. With a condition
    /// block, the put fires only if the condition holds. The condition
    /// closure receives a `Columns` proxy. The canonical
    /// "insert only if not present" guard is
    /// `column.<partitionKey>.doesNotExist`.
    public func put(
        @ConditionBuilder where condition: (Columns) -> [Expression] = { _ in [] }
    ) -> PutItemInput<Self> {
        PutItemInputBuilder.build(item: self, condition: condition(Self.columns))
    }

}
