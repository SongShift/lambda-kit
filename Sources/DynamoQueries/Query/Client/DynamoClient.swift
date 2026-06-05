import Logging

/// The transport-level interface a `DynamoClient` adapter implements. Each
/// method is non-chainable on purpose. Chaining lives on the `*Input` types
/// (`QueryInput`, `ScanInput`, etc.); the client's job is just to ferry a
/// fully built request to DynamoDB and decode the response.
///
/// Every method takes a `logger` the adapter forwards to its transport. Call
/// sites usually don't pass one directly: the `*Input.execute(using:)` family
/// supplies a default (`Logger.dynamoQueriesDisabled`) and an opt-in
/// `execute(using:logger:)` overload threads a real per-request logger through.
public protocol DynamoClient: Sendable {
    func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>,
        logger: Logger
    ) async throws -> QueryPage<Model>

    func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>,
        logger: Logger
    ) async throws -> Model?

    func putItem<Model: DynamoModel>(
        _ input: PutItemInput<Model>,
        logger: Logger
    ) async throws

    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>, logger: Logger) async throws

    /// Run an update and decode the returned attributes into `Model`. Used
    /// by `UpdateReturning.execute(using:)`. Adapters must honor the wrapper's
    /// `returnValues` choice on the wire, throw
    /// `ReturnedAttributesNotFound<Model>` when the response carries no
    /// attributes, and let decoding failures propagate as the decoder's own
    /// error.
    func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>,
        logger: Logger
    ) async throws -> Model

    func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>, logger: Logger) async throws

    func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>,
        logger: Logger
    ) async throws -> QueryPage<Model>

    /// Run a `Select: COUNT` query. Returns counts only — no items decode.
    /// Adapters should set `selectCountOnly` regardless of whether the input
    /// already has it set; the input flag is just a hint.
    func count<Model: DynamoModel>(
        _ input: QueryInput<Model>,
        logger: Logger
    ) async throws -> CountPage

    /// Run a `Select: COUNT` scan. See `count(_:logger:)` for caveats.
    func count<Model: DynamoModel>(
        _ input: ScanInput<Model>,
        logger: Logger
    ) async throws -> CountPage

    /// Run a batch read across multiple keys on a single table. Adapters are
    /// responsible for retrying `UnprocessedKeys` until the response is
    /// fully drained.
    func batchGet<Model: DynamoModel>(
        _ input: BatchGetInput<Model>,
        logger: Logger
    ) async throws -> [Model]

    /// Run a batch write (puts + deletes) against a single table. Adapters
    /// retry `UnprocessedItems` on every response until the remainder is
    /// empty. Note that batch writes don't honor condition expressions —
    /// reach for transact write if you need atomicity.
    func batchWrite<Model: DynamoModel>(
        _ input: BatchWriteInput<Model>,
        logger: Logger
    ) async throws

    /// Run an atomic, all-or-nothing multi-item write. Items can target
    /// different tables. Failures surface as the adapter's native
    /// `TransactionCanceledException` (typed wrapping is future work).
    func transactWrite(_ items: [TransactWriteItem], logger: Logger) async throws

    /// Run an atomic, serializable read of up to 100 items (which may span
    /// tables) in a single `TransactGetItems` call. Returns one optional per
    /// leg, in the order the legs were supplied — a leg whose key matched no
    /// item decodes to `nil`. A read transaction the database cancels (for
    /// example because a conflicting write transaction is in flight) throws
    /// `TransactionCanceled`.
    ///
    /// The transport is erased — a plain `[TransactGetItem]` (each carrying its
    /// storage metatype) in, and a positionally-aligned `[(any DynamoModel)?]`
    /// out, decoded by the adapter. The typed, ordered tuple the caller sees is
    /// rebuilt by `TransactGetInput.execute`. Adapters must return one entry per
    /// requested item, in request order, with `nil` for a key that matched no
    /// item.
    func transactGet(
        _ items: [TransactGetItem],
        logger: Logger
    ) async throws -> [(any DynamoModel)?]
}
