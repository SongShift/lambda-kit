import DynamoQueries

/// A `DynamoClient` that captures the last `Input` it was handed instead of
/// talking to a real DynamoDB. Lets tests build a request via the public DSL
/// (`Model.query { ... }.execute(using: client)`) and then inspect the
/// compiled input that would have gone over the wire.
///
/// Inputs are stored by model `ObjectIdentifier`; tests pull them back with
/// `lastQueryInput(for: Model.self)` (singular = last call) or
/// `recordedQueryInputs(for:)` (plural = full history, in order).
///
/// To exercise pagination, seed the client with a queue of pages via
/// `seedQueryPages(_:for:)` / `seedScanPages(_:for:)`. Each call to
/// `execute` / `scan` pops the head of the matching queue; an empty queue
/// returns an empty page with no token.
///
/// To exercise the conditional-check-failure path, prime an error to throw
/// with `throwOnPut(_:for:)` / `throwOnUpdate(_:for:)` / `throwOnDelete(_:for:)`.
/// The configured error fires once on the next matching call, then clears.
actor RecordingDynamoClient: DynamoClient {
    private var queryInputs: [ObjectIdentifier: [Any]] = [:]
    private var scanInputs: [ObjectIdentifier: [Any]] = [:]
    private var getInputs: [ObjectIdentifier: Any] = [:]
    private var putInputs: [ObjectIdentifier: Any] = [:]
    private var updateInputs: [ObjectIdentifier: Any] = [:]
    private var deleteInputs: [ObjectIdentifier: Any] = [:]
    private var updateReturningInputs: [ObjectIdentifier: Any] = [:]
    private var updateReturnItems: [ObjectIdentifier: Any] = [:]
    private var batchGetInputs: [ObjectIdentifier: Any] = [:]
    private var batchGetResults: [ObjectIdentifier: Any] = [:]
    private var batchWriteInputs: [ObjectIdentifier: Any] = [:]
    private(set) var lastTransactWriteItems: [TransactWriteItem]?
    private var transactWriteError: Error?
    private(set) var lastTransactGetTables: [String]?
    private(set) var lastTransactGetKeys: [[String: DynamoValue]]?
    private var transactGetResults: [Any?] = []
    private var queryPageQueues: [ObjectIdentifier: [Any]] = [:]
    private var scanPageQueues: [ObjectIdentifier: [Any]] = [:]
    private var queryCountQueues: [ObjectIdentifier: [CountPage]] = [:]
    private var scanCountQueues: [ObjectIdentifier: [CountPage]] = [:]
    private var countQueryInputs: [ObjectIdentifier: [Any]] = [:]
    private var countScanInputs: [ObjectIdentifier: [Any]] = [:]
    private var putErrors: [ObjectIdentifier: Error] = [:]
    private var updateErrors: [ObjectIdentifier: Error] = [:]
    private var deleteErrors: [ObjectIdentifier: Error] = [:]

    func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> QueryPage<Model> {
        queryInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popQueryPage(for: Model.self)
    }

    func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>
    ) async throws -> Model? {
        getInputs[ObjectIdentifier(Model.self)] = input
        return nil
    }

    func putItem<Model: DynamoModel>(
        _ input: PutItemInput<Model>
    ) async throws {
        putInputs[ObjectIdentifier(Model.self)] = input
        if let error = putErrors.removeValue(forKey: ObjectIdentifier(Model.self)) {
            throw error
        }
    }

    func updateItem<Model: DynamoModel>(
        _ input: UpdateInput<Model>
    ) async throws {
        updateInputs[ObjectIdentifier(Model.self)] = input
        if let error = updateErrors.removeValue(forKey: ObjectIdentifier(Model.self)) {
            throw error
        }
    }

    func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>
    ) async throws -> Model? {
        updateReturningInputs[ObjectIdentifier(Model.self)] = input
        if let error = updateErrors.removeValue(forKey: ObjectIdentifier(Model.self)) {
            throw error
        }
        return updateReturnItems[ObjectIdentifier(Model.self)] as? Model
    }

    func deleteItem<Model: DynamoModel>(
        _ input: DeleteItemInput<Model>
    ) async throws {
        deleteInputs[ObjectIdentifier(Model.self)] = input
        if let error = deleteErrors.removeValue(forKey: ObjectIdentifier(Model.self)) {
            throw error
        }
    }

    func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> QueryPage<Model> {
        scanInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popScanPage(for: Model.self)
    }

    func count<Model: DynamoModel>(
        _ input: QueryInput<Model>
    ) async throws -> CountPage {
        countQueryInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popQueryCountPage(for: Model.self)
    }

    func count<Model: DynamoModel>(
        _ input: ScanInput<Model>
    ) async throws -> CountPage {
        countScanInputs[ObjectIdentifier(Model.self), default: []].append(input)
        return popScanCountPage(for: Model.self)
    }

    func batchGet<Model: DynamoModel>(
        _ input: BatchGetInput<Model>
    ) async throws -> [Model] {
        batchGetInputs[ObjectIdentifier(Model.self)] = input
        return (batchGetResults[ObjectIdentifier(Model.self)] as? [Model]) ?? []
    }

    func batchWrite<Model: DynamoModel>(
        _ input: BatchWriteInput<Model>
    ) async throws {
        batchWriteInputs[ObjectIdentifier(Model.self)] = input
    }

    func transactWrite(_ items: [TransactWriteItem]) async throws {
        lastTransactWriteItems = items
        if let error = transactWriteError {
            transactWriteError = nil
            throw error
        }
    }

    func throwOnTransactWrite(_ error: Error) {
        transactWriteError = error
    }

    func transactGet<each Model: DynamoModel>(
        _ gets: repeat GetItemInput<each Model>
    ) async throws -> (repeat (each Model)?) {
        var tables: [String] = []
        var keys: [[String: DynamoValue]] = []
        repeat tables.append((each gets).tableName)
        repeat keys.append((each gets).key)
        lastTransactGetTables = tables
        lastTransactGetKeys = keys

        // Seeded results are matched positionally to the legs; an unseeded or
        // wrong-typed slot comes back `nil`, mirroring a not-found item.
        var index = 0
        func next<M: DynamoModel>(_ type: M.Type) -> M? {
            defer { index += 1 }
            guard index < transactGetResults.count else { return nil }
            return transactGetResults[index] as? M
        }
        return (repeat next((each Model).self))
    }

    /// Seed the per-leg results for the next `transactGet`, in declaration
    /// order. Use `nil` for a leg that should read as not-found.
    func seedTransactGetResults(_ items: [Any?]) {
        transactGetResults = items
    }

    // MARK: - Page-queue plumbing

    func seedQueryPages<Model: DynamoModel>(
        _ pages: [QueryPage<Model>],
        for type: Model.Type
    ) {
        queryPageQueues[ObjectIdentifier(type)] = pages
    }

    func seedScanPages<Model: DynamoModel>(
        _ pages: [QueryPage<Model>],
        for type: Model.Type
    ) {
        scanPageQueues[ObjectIdentifier(type)] = pages
    }

    private func popQueryPage<Model: DynamoModel>(for type: Model.Type) -> QueryPage<Model> {
        let id = ObjectIdentifier(type)
        guard var queue = queryPageQueues[id] as? [QueryPage<Model>], !queue.isEmpty else {
            return QueryPage(items: [], nextToken: nil)
        }
        let head = queue.removeFirst()
        queryPageQueues[id] = queue
        return head
    }

    private func popScanPage<Model: DynamoModel>(for type: Model.Type) -> QueryPage<Model> {
        let id = ObjectIdentifier(type)
        guard var queue = scanPageQueues[id] as? [QueryPage<Model>], !queue.isEmpty else {
            return QueryPage(items: [], nextToken: nil)
        }
        let head = queue.removeFirst()
        scanPageQueues[id] = queue
        return head
    }

    func seedQueryCountPages<Model: DynamoModel>(
        _ pages: [CountPage],
        for type: Model.Type
    ) {
        queryCountQueues[ObjectIdentifier(type)] = pages
    }

    func seedScanCountPages<Model: DynamoModel>(
        _ pages: [CountPage],
        for type: Model.Type
    ) {
        scanCountQueues[ObjectIdentifier(type)] = pages
    }

    private func popQueryCountPage<Model: DynamoModel>(for type: Model.Type) -> CountPage {
        let id = ObjectIdentifier(type)
        guard var queue = queryCountQueues[id], !queue.isEmpty else {
            return CountPage(count: 0, scannedCount: 0, nextToken: nil)
        }
        let head = queue.removeFirst()
        queryCountQueues[id] = queue
        return head
    }

    private func popScanCountPage<Model: DynamoModel>(for type: Model.Type) -> CountPage {
        let id = ObjectIdentifier(type)
        guard var queue = scanCountQueues[id], !queue.isEmpty else {
            return CountPage(count: 0, scannedCount: 0, nextToken: nil)
        }
        let head = queue.removeFirst()
        scanCountQueues[id] = queue
        return head
    }

    func recordedCountQueryInputs<Model: DynamoModel>(for type: Model.Type) -> [QueryInput<Model>] {
        (countQueryInputs[ObjectIdentifier(type)] as? [QueryInput<Model>]) ?? []
    }

    func recordedCountScanInputs<Model: DynamoModel>(for type: Model.Type) -> [ScanInput<Model>] {
        (countScanInputs[ObjectIdentifier(type)] as? [ScanInput<Model>]) ?? []
    }

    // MARK: - Error injection

    func throwOnPut<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        putErrors[ObjectIdentifier(type)] = error
    }

    func throwOnUpdate<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        updateErrors[ObjectIdentifier(type)] = error
    }

    func throwOnDelete<Model: DynamoModel>(_ error: Error, for type: Model.Type) {
        deleteErrors[ObjectIdentifier(type)] = error
    }

    // MARK: - Read-back

    func lastQueryInput<Model: DynamoModel>(for type: Model.Type) -> QueryInput<Model>? {
        recordedQueryInputs(for: type).last
    }

    func recordedQueryInputs<Model: DynamoModel>(for type: Model.Type) -> [QueryInput<Model>] {
        (queryInputs[ObjectIdentifier(type)] as? [QueryInput<Model>]) ?? []
    }

    func lastScanInput<Model: DynamoModel>(for type: Model.Type) -> ScanInput<Model>? {
        recordedScanInputs(for: type).last
    }

    func recordedScanInputs<Model: DynamoModel>(for type: Model.Type) -> [ScanInput<Model>] {
        (scanInputs[ObjectIdentifier(type)] as? [ScanInput<Model>]) ?? []
    }

    func lastGetInput<Model: DynamoModel>(for type: Model.Type) -> GetItemInput<Model>? {
        getInputs[ObjectIdentifier(type)] as? GetItemInput<Model>
    }

    func lastPutInput<Model: DynamoModel>(for type: Model.Type) -> PutItemInput<Model>? {
        putInputs[ObjectIdentifier(type)] as? PutItemInput<Model>
    }

    func lastUpdateInput<Model: DynamoModel>(for type: Model.Type) -> UpdateInput<Model>? {
        updateInputs[ObjectIdentifier(type)] as? UpdateInput<Model>
    }

    func lastUpdateReturningInput<Model: DynamoModel>(for type: Model.Type) -> UpdateReturning<Model>? {
        updateReturningInputs[ObjectIdentifier(type)] as? UpdateReturning<Model>
    }

    func seedUpdateReturnItem<Model: DynamoModel>(_ item: Model, for type: Model.Type) {
        updateReturnItems[ObjectIdentifier(type)] = item
    }

    func lastDeleteInput<Model: DynamoModel>(for type: Model.Type) -> DeleteItemInput<Model>? {
        deleteInputs[ObjectIdentifier(type)] as? DeleteItemInput<Model>
    }

    func lastBatchGetInput<Model: DynamoModel>(for type: Model.Type) -> BatchGetInput<Model>? {
        batchGetInputs[ObjectIdentifier(type)] as? BatchGetInput<Model>
    }

    func seedBatchGetResults<Model: DynamoModel>(_ items: [Model], for type: Model.Type) {
        batchGetResults[ObjectIdentifier(type)] = items
    }

    func lastBatchWriteInput<Model: DynamoModel>(for type: Model.Type) -> BatchWriteInput<Model>? {
        batchWriteInputs[ObjectIdentifier(type)] as? BatchWriteInput<Model>
    }
}
