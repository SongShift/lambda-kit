import DynamoQueries

/// A `DynamoClient` whose whole job is to **fail**, so you can test how a
/// repository or service reacts when DynamoDB errors. It throws a configured
/// error on the operations you point it at; every other operation is a benign
/// no-op (writes succeed silently, reads return empty).
///
/// By default it fails on *every* operation:
///
///     let client = FailingDynamoClient(DynamoFailure(reason: .throttled))
///     let failure = try await expectDynamoFailure(.throttled) {
///         try await service.placeOrder(using: client)
///     }
///     #expect(failure.isRetryable)
///
/// Scope the failure when a service does several calls and you want only one to
/// fail — e.g. the read succeeds but the write is throttled:
///
///     let client = FailingDynamoClient(DynamoFailure(reason: .throttled), on: .writes)
///
/// This fills a gap `RecordingDynamoClient` can't: it can fail *reads*
/// (`get`/`query`/`scan`/`batchGet`/`transactGet`), not just writes.
///
/// The error must be `Sendable` (it crosses back to the caller across the
/// actor boundary). The lambda-kit error types — `DynamoFailure`,
/// `ConditionalCheckFailed<Model>`, `TransactionCanceled` — all qualify.
public actor FailingDynamoClient: DynamoClient {

    /// The DynamoDB operations a `FailingDynamoClient` can be told to fail on.
    public enum Operation: Sendable, CaseIterable {
        case query, scan, get, count, batchGet, transactGet   // reads
        case put, update, delete, batchWrite, transactWrite   // writes
    }

    /// Type-erased conditional-conflict descriptor: which model it applies to,
    /// and how to build the typed `ConditionalCheckFailed` given the request's
    /// `.returnConflictingItem()` opt-in.
    private struct ConflictBox: Sendable {
        let modelID: ObjectIdentifier
        let make: @Sendable (_ returnPrior: Bool) -> any Error & Sendable
    }

    private let error: (any Error & Sendable)?
    private let failing: Set<Operation>
    private let conflict: ConflictBox?

    /// Fail with `error` on the given `operations` (all of them by default).
    public init(
        _ error: any Error & Sendable,
        on operations: Set<Operation> = .all
    ) {
        self.error = error
        self.failing = operations
        self.conflict = nil
    }

    /// Convenience: fail with a `DynamoFailure` of the given reason.
    public init(
        reason: DynamoFailure.Reason,
        message: String? = nil,
        on operations: Set<Operation> = .all
    ) {
        self.error = DynamoFailure(reason: reason, message: message)
        self.failing = operations
        self.conflict = nil
    }

    private init(conflict: ConflictBox) {
        self.error = nil
        self.failing = []
        self.conflict = conflict
    }

    /// Simulate a conditional-check conflict for `Model`'s conditional writes
    /// (`put` / `update` / `delete`), exactly as a real adapter does: the thrown
    /// `ConditionalCheckFailed<Model>` carries `conflictingItem` as its
    /// `priorItem` **only** when the request opted in via
    /// `.returnConflictingItem()`, and `nil` otherwise. Reads, and writes to
    /// other models, are benign no-ops.
    ///
    ///     let client = FailingDynamoClient.conditionalConflict(
    ///         for: PhotoScan.self, tableName: "TrailPhotoScans", conflictingItem: prior)
    ///
    ///     let failure = try await expectConditionalCheckFailure(of: PhotoScan.self) {
    ///         try await scan.put { $0.id.doesNotExist }
    ///             .returnConflictingItem()                  // opt in → priorItem populated
    ///             .execute(using: client)
    ///     }
    ///     #expect(failure.priorItem?.status == prior.status)
    public static func conditionalConflict<Model: DynamoModel>(
        for type: Model.Type,
        tableName: String,
        conflictingItem: Model? = nil
    ) -> FailingDynamoClient {
        let box = ConflictBox(modelID: ObjectIdentifier(type)) { returnPrior in
            ConditionalCheckFailed<Model>(
                tableName: tableName,
                priorItem: returnPrior ? conflictingItem : nil
            )
        }
        return FailingDynamoClient(conflict: box)
    }

    private func failIfNeeded(_ operation: Operation) throws {
        if let error, failing.contains(operation) { throw error }
    }

    /// If a conditional conflict is configured for `Model`, throw it — honoring
    /// the request's `.returnConflictingItem()` opt-in.
    private func failConditionalConflict<Model: DynamoModel>(
        _ type: Model.Type,
        returnPrior: Bool
    ) throws {
        guard let conflict, conflict.modelID == ObjectIdentifier(type) else { return }
        throw conflict.make(returnPrior)
    }

    // MARK: - DynamoClient

    public func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> QueryPage<Model> {
        try failIfNeeded(.query)
        return QueryPage(items: [], nextToken: nil)
    }

    public func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>
    ) async throws -> Model? {
        try failIfNeeded(.get)
        return nil
    }

    public func putItem<Model: DynamoModel>(_ input: PutItemInput<Model>) async throws {
        try failConditionalConflict(Model.self, returnPrior: input.returnPriorOnConflict)
        try failIfNeeded(.put)
    }

    public func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>) async throws {
        try failConditionalConflict(Model.self, returnPrior: input.returnPriorOnConflict)
        try failIfNeeded(.update)
    }

    public func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>
    ) async throws -> Model? {
        try failConditionalConflict(Model.self, returnPrior: input.input.returnPriorOnConflict)
        try failIfNeeded(.update)
        return nil
    }

    public func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>) async throws {
        try failConditionalConflict(Model.self, returnPrior: input.returnPriorOnConflict)
        try failIfNeeded(.delete)
    }

    public func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> QueryPage<Model> {
        try failIfNeeded(.scan)
        return QueryPage(items: [], nextToken: nil)
    }

    public func count<Model: DynamoModel>(_ input: QueryInput<Model>) async throws -> CountPage {
        try failIfNeeded(.count)
        return CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    public func count<Model: DynamoModel>(_ input: ScanInput<Model>) async throws -> CountPage {
        try failIfNeeded(.count)
        return CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    public func batchGet<Model: DynamoModel>(_ input: BatchGetInput<Model>) async throws -> [Model] {
        try failIfNeeded(.batchGet)
        return []
    }

    public func batchWrite<Model: DynamoModel>(_ input: BatchWriteInput<Model>) async throws {
        try failIfNeeded(.batchWrite)
    }

    public func transactWrite(_ items: [TransactWriteItem]) async throws {
        try failIfNeeded(.transactWrite)
    }

    public func transactGet(_ items: [TransactGetItem]) async throws -> [(any DynamoModel)?] {
        try failIfNeeded(.transactGet)
        return items.map { _ in nil }
    }
}

extension Set where Element == FailingDynamoClient.Operation {
    /// Every operation.
    public static var all: Self { Set(Element.allCases) }
    /// Reads only: `query`, `scan`, `get`, `count`, `batchGet`, `transactGet`.
    public static var reads: Self { [.query, .scan, .get, .count, .batchGet, .transactGet] }
    /// Writes only: `put`, `update`, `delete`, `batchWrite`, `transactWrite`.
    public static var writes: Self { [.put, .update, .delete, .batchWrite, .transactWrite] }
}
