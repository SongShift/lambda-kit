import DynamoQueries

/// A programmable `DynamoClient` test double — a **stub + spy**. It never talks
/// to DynamoDB; instead it:
///
/// 1. **Records** every request, both as the typed input (read back with
///    `lastQueryInput(for:)` / `recordedQueryInputs(for:)` etc.) and as a
///    rendered string appended to ``requestLog`` (snapshot ``transcript`` to pin
///    the whole sequence a repository or service emits).
/// 2. **Returns canned responses** you seed ahead of time — `seedGetItem`,
///    `seedQueryPages`, `seedBatchGetResults`, `seedTransactGetResults`, …
/// 3. **Injects errors** that fire once on the next matching call, then clear —
///    `throwOnPut` / `throwOnUpdate` / `throwOnDelete` / `throwOnTransactWrite`.
///
/// It does **not** store items: a `get` after a `put` returns whatever you
/// seeded for `get`, not the put item. Reach for this when you want to assert
/// *what was sent* and drive reads with fixed data; reach for a stateful fake
/// when you need real round-trip behaviour.
///
/// Inputs are keyed by model `ObjectIdentifier`. Query/scan/count keep the full
/// call history (`recordedQueryInputs` = all, `lastQueryInput` = most recent);
/// the single-item operations keep only the last call.
public actor RecordingDynamoClient: DynamoClient {

    public init() {}

    // MARK: - Request log (spy, rendered)

    /// Every request handled, rendered in order. Append-only.
    public private(set) var requestLog: [String] = []

    /// The request log as one blank-line-separated string — snapshot this to
    /// pin a multi-request operation.
    public var transcript: String {
        requestLog.joined(separator: "\n\n")
    }

    /// Clear the request log. Seeded responses and pending errors are kept.
    public func clearLog() {
        requestLog.removeAll()
    }

    private func log(_ request: some RenderableRequest) {
        requestLog.append(request.renderedRequest)
    }

    // MARK: - Captured inputs

    private var queryInputs: [ObjectIdentifier: [Any]] = [:]
    private var scanInputs: [ObjectIdentifier: [Any]] = [:]
    private var getInputs: [ObjectIdentifier: Any] = [:]
    private var putInputs: [ObjectIdentifier: Any] = [:]
    private var updateInputs: [ObjectIdentifier: Any] = [:]
    private var deleteInputs: [ObjectIdentifier: Any] = [:]
    private var updateReturningInputs: [ObjectIdentifier: Any] = [:]
    private var batchGetInputs: [ObjectIdentifier: Any] = [:]
    private var batchWriteInputs: [ObjectIdentifier: Any] = [:]
    private var countQueryInputs: [ObjectIdentifier: [Any]] = [:]
    private var countScanInputs: [ObjectIdentifier: [Any]] = [:]
    public private(set) var lastTransactWriteItems: [TransactWriteItem]?
    public private(set) var lastTransactGetItems: [TransactGetItem]?

    // MARK: - Seeded responses

    private var queryPageQueues: [ObjectIdentifier: [Any]] = [:]
    private var scanPageQueues: [ObjectIdentifier: [Any]] = [:]
    private var queryCountQueues: [ObjectIdentifier: [CountPage]] = [:]
    private var scanCountQueues: [ObjectIdentifier: [CountPage]] = [:]
    private var getItems: [ObjectIdentifier: Any] = [:]
    private var batchGetResults: [ObjectIdentifier: Any] = [:]
    private var updateReturnItems: [ObjectIdentifier: Any] = [:]
    private var transactGetResults: [(any DynamoModel)?] = []

    // MARK: - Injected errors

    private var putErrors: [ObjectIdentifier: Error] = [:]
    private var updateErrors: [ObjectIdentifier: Error] = [:]
    private var deleteErrors: [ObjectIdentifier: Error] = [:]
    private var transactWriteError: Error?

    // MARK: - DynamoClient

    public func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> QueryPage<Model> {
        log(input)
        queryInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popQueryPage(for: Model.self)
    }

    public func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>
    ) async throws -> Model? {
        log(input)
        getInputs[ObjectIdentifier(Model.self)] = input
        return getItems[ObjectIdentifier(Model.self)] as? Model
    }

    public func putItem<Model: DynamoModel>(
        _ input: PutItemInput<Model>
    ) async throws {
        log(input)
        putInputs[ObjectIdentifier(Model.self)] = input
        try throwIfPrimed(&putErrors, Model.self)
    }

    public func updateItem<Model: DynamoModel>(
        _ input: UpdateInput<Model>
    ) async throws {
        log(input)
        updateInputs[ObjectIdentifier(Model.self)] = input
        try throwIfPrimed(&updateErrors, Model.self)
    }

    public func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>
    ) async throws -> Model? {
        log(input)
        updateReturningInputs[ObjectIdentifier(Model.self)] = input
        try throwIfPrimed(&updateErrors, Model.self)
        return updateReturnItems[ObjectIdentifier(Model.self)] as? Model
    }

    public func deleteItem<Model: DynamoModel>(
        _ input: DeleteItemInput<Model>
    ) async throws {
        log(input)
        deleteInputs[ObjectIdentifier(Model.self)] = input
        try throwIfPrimed(&deleteErrors, Model.self)
    }

    public func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> QueryPage<Model> {
        log(input)
        scanInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popScanPage(for: Model.self)
    }

    public func count<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> CountPage {
        log(input)
        countQueryInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popQueryCountPage(for: Model.self)
    }

    public func count<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> CountPage {
        log(input)
        countScanInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popScanCountPage(for: Model.self)
    }

    public func batchGet<Model: DynamoModel>(
        _ input: BatchGetInput<Model>
    ) async throws -> [Model] {
        log(input)
        batchGetInputs[ObjectIdentifier(Model.self)] = input
        return (batchGetResults[ObjectIdentifier(Model.self)] as? [Model]) ?? []
    }

    public func batchWrite<Model: DynamoModel>(
        _ input: BatchWriteInput<Model>
    ) async throws {
        log(input)
        batchWriteInputs[ObjectIdentifier(Model.self)] = input
    }

    public func transactWrite(_ items: [TransactWriteItem]) async throws {
        requestLog.append("TransactWrite legs=\(items.count) tables=\(items.map(\.tableName))")
        lastTransactWriteItems = items
        if let error = transactWriteError {
            transactWriteError = nil
            throw error
        }
    }

    public func transactGet(
        _ items: [TransactGetItem]
    ) async throws -> [(any DynamoModel)?] {
        requestLog.append("TransactGet legs=\(items.count) tables=\(items.map(\.tableName))")
        lastTransactGetItems = items
        // Seeded results are matched positionally to the legs; an unseeded slot
        // comes back `nil`, mirroring a not-found item.
        return (0..<items.count).map { index in
            index < transactGetResults.count ? transactGetResults[index] : nil
        }
    }

    // MARK: - Seeding

    public func seedQueryPages<Model: DynamoModel>(_ pages: [QueryPage<Model>], for type: Model.Type) {
        queryPageQueues[ObjectIdentifier(type)] = pages
    }

    public func seedScanPages<Model: DynamoModel>(_ pages: [QueryPage<Model>], for type: Model.Type) {
        scanPageQueues[ObjectIdentifier(type)] = pages
    }

    public func seedQueryCountPages<Model: DynamoModel>(_ pages: [CountPage], for type: Model.Type) {
        queryCountQueues[ObjectIdentifier(type)] = pages
    }

    public func seedScanCountPages<Model: DynamoModel>(_ pages: [CountPage], for type: Model.Type) {
        scanCountQueues[ObjectIdentifier(type)] = pages
    }

    public func seedGetItem<Model: DynamoModel>(_ item: Model?, for type: Model.Type) {
        getItems[ObjectIdentifier(type)] = item
    }

    public func seedBatchGetResults<Model: DynamoModel>(_ items: [Model], for type: Model.Type) {
        batchGetResults[ObjectIdentifier(type)] = items
    }

    public func seedUpdateReturnItem<Model: DynamoModel>(_ item: Model, for type: Model.Type) {
        updateReturnItems[ObjectIdentifier(type)] = item
    }

    /// Seed the per-leg results for the next `transactGet`, in declaration
    /// order. Use `nil` for a leg that should read as not-found.
    public func seedTransactGetResults(_ items: [(any DynamoModel)?]) {
        transactGetResults = items
    }

    // MARK: - Error injection

    public func throwOnPut<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        putErrors[ObjectIdentifier(type)] = error
    }

    public func throwOnUpdate<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        updateErrors[ObjectIdentifier(type)] = error
    }

    public func throwOnDelete<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        deleteErrors[ObjectIdentifier(type)] = error
    }

    public func throwOnTransactWrite(_ error: Error) {
        transactWriteError = error
    }

    // MARK: - Read-back

    public func lastQueryInput<Model: DynamoModel>(for type: Model.Type) -> QueryInput<Model>? {
        recordedQueryInputs(for: type).last
    }

    public func recordedQueryInputs<Model: DynamoModel>(for type: Model.Type) -> [QueryInput<Model>] {
        (queryInputs[ObjectIdentifier(type)] as? [QueryInput<Model>]) ?? []
    }

    public func lastScanInput<Model: DynamoModel>(for type: Model.Type) -> ScanInput<Model>? {
        recordedScanInputs(for: type).last
    }

    public func recordedScanInputs<Model: DynamoModel>(for type: Model.Type) -> [ScanInput<Model>] {
        (scanInputs[ObjectIdentifier(type)] as? [ScanInput<Model>]) ?? []
    }

    public func recordedCountQueryInputs<Model: DynamoModel>(for type: Model.Type) -> [QueryInput<Model>] {
        (countQueryInputs[ObjectIdentifier(type)] as? [QueryInput<Model>]) ?? []
    }

    public func recordedCountScanInputs<Model: DynamoModel>(for type: Model.Type) -> [ScanInput<Model>] {
        (countScanInputs[ObjectIdentifier(type)] as? [ScanInput<Model>]) ?? []
    }

    public func lastGetInput<Model: DynamoModel>(for type: Model.Type) -> GetItemInput<Model>? {
        getInputs[ObjectIdentifier(type)] as? GetItemInput<Model>
    }

    public func lastPutInput<Model: DynamoModel>(for type: Model.Type) -> PutItemInput<Model>? {
        putInputs[ObjectIdentifier(type)] as? PutItemInput<Model>
    }

    public func lastUpdateInput<Model: DynamoModel>(for type: Model.Type) -> UpdateInput<Model>? {
        updateInputs[ObjectIdentifier(type)] as? UpdateInput<Model>
    }

    public func lastUpdateReturningInput<Model: DynamoModel>(for type: Model.Type) -> UpdateReturning<Model>? {
        updateReturningInputs[ObjectIdentifier(type)] as? UpdateReturning<Model>
    }

    public func lastDeleteInput<Model: DynamoModel>(for type: Model.Type) -> DeleteItemInput<Model>? {
        deleteInputs[ObjectIdentifier(type)] as? DeleteItemInput<Model>
    }

    public func lastBatchGetInput<Model: DynamoModel>(for type: Model.Type) -> BatchGetInput<Model>? {
        batchGetInputs[ObjectIdentifier(type)] as? BatchGetInput<Model>
    }

    public func lastBatchWriteInput<Model: DynamoModel>(for type: Model.Type) -> BatchWriteInput<Model>? {
        batchWriteInputs[ObjectIdentifier(type)] as? BatchWriteInput<Model>
    }

    // MARK: - Queue helpers

    private func popQueryPage<Model: DynamoModel>(for type: Model.Type) -> QueryPage<Model> {
        popPage(&queryPageQueues, type)
    }

    private func popScanPage<Model: DynamoModel>(for type: Model.Type) -> QueryPage<Model> {
        popPage(&scanPageQueues, type)
    }

    private func popPage<Model: DynamoModel>(
        _ queues: inout [ObjectIdentifier: [Any]],
        _ type: Model.Type
    ) -> QueryPage<Model> {
        let id = ObjectIdentifier(type)
        guard var queue = queues[id] as? [QueryPage<Model>], !queue.isEmpty else {
            return QueryPage(items: [], nextToken: nil)
        }
        let head = queue.removeFirst()
        queues[id] = queue
        return head
    }

    private func popQueryCountPage<Model: DynamoModel>(for type: Model.Type) -> CountPage {
        popCount(&queryCountQueues, type)
    }

    private func popScanCountPage<Model: DynamoModel>(for type: Model.Type) -> CountPage {
        popCount(&scanCountQueues, type)
    }

    private func popCount<Model: DynamoModel>(
        _ queues: inout [ObjectIdentifier: [CountPage]],
        _ type: Model.Type
    ) -> CountPage {
        let id = ObjectIdentifier(type)
        guard var queue = queues[id], !queue.isEmpty else {
            return CountPage(count: 0, scannedCount: 0, nextToken: nil)
        }
        let head = queue.removeFirst()
        queues[id] = queue
        return head
    }

    private func throwIfPrimed<Model: DynamoModel>(
        _ errors: inout [ObjectIdentifier: Error],
        _ type: Model.Type
    ) throws {
        if let error = errors.removeValue(forKey: ObjectIdentifier(type)) {
            throw error
        }
    }
}
