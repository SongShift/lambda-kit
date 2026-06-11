/// A typed reference to a DynamoDB secondary index on `Model`.
///
/// Indexes carry their own partition/sort key shape that may differ from the
/// base table's. Once you have an `Index<Self>`, queries against it look like
/// queries against the base table. The same builder DSL applies, just with
/// the index's keys.
///
/// GSIs support multi-attribute keys: up to four attributes hashed together
/// as the partition key and up to four more as a hierarchical sort key.
/// DynamoDB requires an equality condition on *every* partition-key
/// attribute. Sort-key attributes are constrained left-to-right, with at
/// most one trailing range condition (`<`, `between`, `beginsWith`, …).
///
/// Most call sites should use the macro-generated `Model.Indexes.X` instances
/// rather than constructing `Index` values by hand. Manual construction is
/// available for ad-hoc use (e.g. an index that wasn't declared via `@Index`
/// on the struct).
public struct Index<Model: DynamoModel>: Sendable {
    public let name: String
    public let partitionKeys: [KeyAttribute]
    public let sortKeys: [KeyAttribute]

    public init(name: String, partitionKeys: [KeyAttribute], sortKeys: [KeyAttribute] = []) {
        self.name = name
        self.partitionKeys = partitionKeys
        self.sortKeys = sortKeys
    }

    public init(name: String, partitionKey: KeyAttribute, sortKey: KeyAttribute? = nil) {
        self.init(
            name: name,
            partitionKeys: [partitionKey],
            sortKeys: sortKey.map { [$0] } ?? []
        )
    }
}
