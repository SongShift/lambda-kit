/// A typed reference to a DynamoDB secondary index on `Model`.
///
/// Indexes carry their own partition/sort key shape that may differ from the
/// base table's. Once you have an `Index<Self>`, queries against it look like
/// queries against the base table. The same builder DSL applies, just with
/// the index's keys.
///
/// Most call sites should use the macro-generated `Model.Indexes.X` instances
/// rather than constructing `Index` values by hand. Manual construction is
/// available for ad-hoc use (e.g. an index that wasn't declared via `@Index`
/// on the struct).
public struct Index<Model: DynamoModel>: Sendable {
    public let name: String
    public let partitionKey: String
    public let sortKey: String?

    public init(name: String, partitionKey: String, sortKey: String? = nil) {
        self.name = name
        self.partitionKey = partitionKey
        self.sortKey = sortKey
    }
}
