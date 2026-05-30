/// The transport-level interface a `DynamoClient` adapter implements. Each
/// method is non-chainable on purpose. Chaining lives on the `*Input` types
/// (`QueryInput`, `ScanInput`, etc.); the client's job is just to ferry a
/// fully built request to DynamoDB and decode the response.
public protocol DynamoClient: Sendable {
    func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> QueryPage<Model>

    func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>
    ) async throws -> Model?

    func putItem<Model: DynamoModel>(
        _ input: PutItemInput<Model>
    ) async throws

    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>) async throws

    /// Run an update and decode the returned attributes into `Model`. Used
    /// by `UpdateReturning.execute(using:)`. Adapters must honor the wrapper's
    /// `returnValues` choice on the wire.
    func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>
    ) async throws -> Model?

    func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>) async throws

    func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> QueryPage<Model>

    /// Run a `Select: COUNT` query. Returns counts only, no items decode.
    /// Adapters should set `selectCountOnly` regardless of whether the input
    /// already has it set; the input flag is just a hint.
    func count<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> CountPage

    /// Run a `Select: COUNT` scan. See `count(_:)` for caveats.
    func count<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> CountPage

    /// Run a batch read across multiple keys on a single table. Adapters are
    /// responsible for retrying `UnprocessedKeys` until the response is
    /// fully drained.
    func batchGet<Model: DynamoModel>(
        _ input: BatchGetInput<Model>
    ) async throws -> [Model]

    /// Run a batch write (puts + deletes) against a single table. Adapters
    /// retry `UnprocessedItems` on every response until the remainder is
    /// empty. Note that batch writes don't honor condition expressions.
    /// Reach for transact write if you need atomicity.
    func batchWrite<Model: DynamoModel>(
        _ input: BatchWriteInput<Model>
    ) async throws

    /// Run an atomic, all-or-nothing multi-item write. Items can target
    /// different tables. Failures surface as the adapter's native
    /// `TransactionCanceledException` (typed wrapping is future work).
    func transactWrite(_ items: [TransactWriteItem]) async throws

    /// Run an atomic, serializable read of up to 100 items (which may span
    /// tables) in a single `TransactGetItems` call. Returns one optional per
    /// leg, in the order the legs were supplied. A leg whose key matched no
    /// item decodes to `nil`. A read transaction the database cancels (for
    /// example because a conflicting write transaction is in flight) throws
    /// `TransactionCanceled`.
    ///
    /// The transport is erased: a plain `[TransactGetItem]` (each carrying its
    /// storage metatype) in, and a positionally-aligned `[(any DynamoModel)?]`
    /// out, decoded by the adapter. The typed, ordered tuple the caller sees is
    /// rebuilt by `TransactGetInput.execute`. Adapters must return one entry per
    /// requested item, in request order, with `nil` for a key that matched no
    /// item.
    func transactGet(
        _ items: [TransactGetItem]
    ) async throws -> [(any DynamoModel)?]
}
