import DynamoQueries
import Logging
import SotoDynamoDB
import Foundation

// MARK: - Helpers

private func nonEmpty(_ map: [String: String]?) -> [String: String]? {
    guard let map, !map.isEmpty else { return nil }
    return map
}

private func nonEmpty(_ map: [String: DynamoValue]?) -> [String: DynamoDB.AttributeValue]? {
    guard let map, !map.isEmpty else { return nil }
    return map.mapValues { $0.toSotoAttributeValue() }
}

// MARK: - Conditional-check failure translation
//
// Soto raises conditional-check failures as `DynamoDBErrorType` values whose
// extended-error payload carries the conflicting item (when the request
// asked for it). The DynamoQueries contract is a typed
// `ConditionalCheckFailed<Model>`, so every write path goes through this
// wrapper.

private func translatingConditionalCheckFailures<Model: DynamoModel>(
    table: String,
    as type: Model.Type,
    _ block: () async throws -> Void
) async throws {
    do {
        try await block()
    } catch let error as DynamoDBErrorType where error == .conditionalCheckFailedException {
        var prior: Model? = nil
        if let extended = error.context?.extendedError as? DynamoDB.ConditionalCheckFailedException,
           let item = extended.item {
            prior = try? DynamoDecoder.decode(Model.self, from: item)
        }
        throw ConditionalCheckFailed<Model>(tableName: table, priorItem: prior)
    }
}

private func translatingTransactionFailures<T>(
    _ block: () async throws -> T
) async throws -> T {
    do {
        return try await block()
    } catch let error as DynamoDBErrorType where error == .transactionCanceledException {
        let extended = error.context?.extendedError as? DynamoDB.TransactionCanceledException
        let reasons = extended?.cancellationReasons ?? []
        let cancellations = reasons.enumerated().map { index, reason in
            TransactionCanceled.Cancellation(
                index: index,
                failure: cancellationFailure(code: reason.code, message: reason.message),
                priorRawItem: reason.item.map { $0.mapValues { $0.toDynamoValue() } }
            )
        }
        throw TransactionCanceled(cancellations: cancellations)
    }
}

/// Generic translator for `DynamoDBErrorType` → `DynamoFailure`. Wrap every
/// adapter operation in this *outside* the typed-payload translators
/// (`translatingConditionalCheckFailures`, `translatingTransactionFailures`)
/// so the typed cases take precedence and only "everything else" reaches
/// the generic mapping.
private func translatingDynamoFailures<T>(
    _ block: () async throws -> T
) async throws -> T {
    do {
        return try await block()
    } catch let error as DynamoDBErrorType {
        throw error.toDynamoFailure()
    }
}

private extension DynamoDBErrorType {
    func toDynamoFailure() -> DynamoFailure {
        let reason: DynamoFailure.Reason
        switch self {
        case .provisionedThroughputExceededException:
            reason = .throughputExceeded
        case .throttlingException:
            reason = .throttled
        case .transactionConflictException:
            reason = .transactionConflict
        case .transactionInProgressException:
            reason = .transactionInProgress
        case .internalServerError:
            reason = .internalServerError
        case .resourceNotFoundException:
            reason = .resourceNotFound
        case .resourceInUseException:
            reason = .resourceNotFound
        default:
            reason = .unknown(code: nil)
        }
        return DynamoFailure(reason: reason, message: self.message)
    }
}

private func cancellationFailure(code: String?, message: String?) -> DynamoFailure? {
    guard let code, code != "None" else { return nil }
    let reason: DynamoFailure.Reason
    switch code {
    case "ConditionalCheckFailed":
        reason = .conditionalCheckFailed
    case "TransactionConflict":
        reason = .transactionConflict
    case "ProvisionedThroughputExceeded":
        reason = .throughputExceeded
    case "ThrottlingError":
        reason = .throttled
    case "ValidationError":
        reason = .validation
    case "ItemCollectionSizeLimitExceeded":
        reason = .itemCollectionSizeLimitExceeded
    case "DuplicateItem":
        reason = .duplicateItem
    default:
        reason = .unknown(code: code)
    }
    return DynamoFailure(reason: reason, message: message)
}

// MARK: - Projection placeholdering
//
// Every name in `projectionAttributes` is rewritten as a `#pN` placeholder so
// reserved words (status, name, count, ...) survive the round trip. The `#p`
// prefix is disjoint from the `#n` namespace the `ExpressionCompiler`
// allocates into, so merging the two `expressionAttributeNames` maps is a
// straight union with no collisions.
private func resolveProjection(
    attributes: [String]?,
    existingNames: [String: String]
) -> (expression: String?, mergedNames: [String: String]) {
    guard let attributes, !attributes.isEmpty else {
        return (nil, existingNames)
    }
    var merged = existingNames
    var placeholders: [String] = []
    for (index, name) in attributes.enumerated() {
        let placeholder = "#p\(index)"
        merged[placeholder] = name
        placeholders.append(placeholder)
    }
    return (placeholders.joined(separator: ", "), merged)
}

// MARK: - Input → Soto conversion

extension DynamoQueries.QueryInput {
    /// Converts a DynamoQueries `QueryInput` to Soto's `DynamoDB.QueryInput`.
    ///
    /// Pass `tableNameOverride` to substitute a different on-the-wire table
    /// name than the one the input was built with. `SotoDynamoClient` uses
    /// this to apply its configured environment suffix.
    public func toSotoQueryInput(tableNameOverride: String? = nil) -> DynamoDB.QueryInput {
        let (projection, names) = resolveProjection(
            attributes: projectionAttributes,
            existingNames: expressionAttributeNames
        )
        return DynamoDB.QueryInput(
            consistentRead: consistentRead ? true : nil,
            exclusiveStartKey: exclusiveStartKey?.mapValues { $0.toSotoAttributeValue() },
            expressionAttributeNames: names.isEmpty ? nil : names,
            expressionAttributeValues: expressionAttributeValues.isEmpty ? nil : expressionAttributeValues.mapValues {
                $0.toSotoAttributeValue()
            },
            filterExpression: filterExpression,
            indexName: indexName,
            keyConditionExpression: keyConditionExpression,
            limit: limit.map { Int($0) },
            projectionExpression: projection,
            scanIndexForward: scanIndexForward,
            select: selectCountOnly ? .count : nil,
            tableName: tableNameOverride ?? tableName
        )
    }
}

extension DynamoQueries.ScanInput {
    public func toSotoScanInput(tableNameOverride: String? = nil) -> DynamoDB.ScanInput {
        let (projection, names) = resolveProjection(
            attributes: projectionAttributes,
            existingNames: expressionAttributeNames
        )
        return DynamoDB.ScanInput(
            consistentRead: consistentRead ? true : nil,
            exclusiveStartKey: exclusiveStartKey?.mapValues { $0.toSotoAttributeValue() },
            expressionAttributeNames: names.isEmpty ? nil : names,
            expressionAttributeValues: expressionAttributeValues.isEmpty
                ? nil : expressionAttributeValues.mapValues { $0.toSotoAttributeValue() },
            filterExpression: filterExpression,
            indexName: indexName,
            limit: limit.map { Int($0) },
            projectionExpression: projection,
            select: selectCountOnly ? .count : nil,
            tableName: tableNameOverride ?? tableName
        )
    }
}

extension DynamoQueries.GetItemInput {
    public func toSotoGetItemInput(tableNameOverride: String? = nil) -> DynamoDB.GetItemInput {
        let (projection, names) = resolveProjection(
            attributes: projectionAttributes,
            existingNames: [:]
        )
        return DynamoDB.GetItemInput(
            consistentRead: consistentRead ? true : nil,
            expressionAttributeNames: names.isEmpty ? nil : names,
            key: key.mapValues { $0.toSotoAttributeValue() },
            projectionExpression: projection,
            tableName: tableNameOverride ?? tableName
        )
    }

    /// Converts this get into a `DynamoDB.Get`: the leg shape `TransactGetItems`
    /// expects. `consistentRead` is intentionally dropped: read transactions are
    /// always serializable and have no per-item consistency setting.
    public func toSotoGet(tableNameOverride: String? = nil) -> DynamoDB.Get {
        let (projection, names) = resolveProjection(
            attributes: projectionAttributes,
            existingNames: [:]
        )
        return DynamoDB.Get(
            expressionAttributeNames: names.isEmpty ? nil : names,
            key: key.mapValues { $0.toSotoAttributeValue() },
            projectionExpression: projection,
            tableName: tableNameOverride ?? tableName
        )
    }
}

extension DynamoQueries.DeleteItemInput {
    public func toSotoDeleteItemInput(tableNameOverride: String? = nil) -> DynamoDB.DeleteItemInput {
        DynamoDB.DeleteItemInput(
            conditionExpression: conditionExpression,
            expressionAttributeNames: expressionAttributeNames.isEmpty
                ? nil : expressionAttributeNames,
            expressionAttributeValues: expressionAttributeValues.isEmpty
                ? nil : expressionAttributeValues.mapValues { $0.toSotoAttributeValue() },
            key: key.mapValues { $0.toSotoAttributeValue() },
            returnValuesOnConditionCheckFailure: returnPriorOnConflict ? .allOld : nil,
            tableName: tableNameOverride ?? tableName
        )
    }
}

extension DynamoQueries.UpdateInput {
    public func toSotoUpdateItemInput(tableNameOverride: String? = nil) -> DynamoDB.UpdateItemInput {
        DynamoDB.UpdateItemInput(
            conditionExpression: conditionExpression,
            expressionAttributeNames: expressionAttributeNames.isEmpty
                ? nil : expressionAttributeNames,
            expressionAttributeValues: expressionAttributeValues.isEmpty
                ? nil : expressionAttributeValues.mapValues { $0.toSotoAttributeValue() },
            key: key.mapValues { $0.toSotoAttributeValue() },
            returnValuesOnConditionCheckFailure: returnPriorOnConflict ? .allOld : nil,
            tableName: tableNameOverride ?? tableName,
            updateExpression: updateExpression
        )
    }
}

extension DynamoQueries.UpdateReturning {
    public func toSotoUpdateItemInput(tableNameOverride: String? = nil) -> DynamoDB.UpdateItemInput {
        let underlying = input
        return DynamoDB.UpdateItemInput(
            conditionExpression: underlying.conditionExpression,
            expressionAttributeNames: underlying.expressionAttributeNames.isEmpty
                ? nil : underlying.expressionAttributeNames,
            expressionAttributeValues: underlying.expressionAttributeValues.isEmpty
                ? nil : underlying.expressionAttributeValues.mapValues { $0.toSotoAttributeValue() },
            key: underlying.key.mapValues { $0.toSotoAttributeValue() },
            returnValues: returnValues.toSotoReturnValue(),
            returnValuesOnConditionCheckFailure: underlying.returnPriorOnConflict ? .allOld : nil,
            tableName: tableNameOverride ?? underlying.tableName,
            updateExpression: underlying.updateExpression
        )
    }
}

extension DynamoQueries.UpdateReturnValues {
    public func toSotoReturnValue() -> DynamoDB.ReturnValue {
        switch self {
        case .allNew: return .allNew
        case .allOld: return .allOld
        case .updatedNew: return .updatedNew
        case .updatedOld: return .updatedOld
        }
    }
}

extension DynamoQueries.PutItemInput {
    /// Builds the Soto request for this put, encoding the model item via
    /// the adapter's JSON-bridging encoder.
    public func toSotoPutItemInput(tableNameOverride: String? = nil) throws -> DynamoDB.PutItemInput {
        let encodedItem = try DynamoEncoder.encode(item)
        return DynamoDB.PutItemInput(
            conditionExpression: conditionExpression,
            expressionAttributeNames: expressionAttributeNames.isEmpty
                ? nil : expressionAttributeNames,
            expressionAttributeValues: expressionAttributeValues.isEmpty
                ? nil : expressionAttributeValues.mapValues { $0.toSotoAttributeValue() },
            item: encodedItem,
            returnValuesOnConditionCheckFailure: returnPriorOnConflict ? .allOld : nil,
            tableName: tableNameOverride ?? tableName
        )
    }
}

// MARK: - SotoDynamoClient

public struct SotoDynamoClient: DynamoClient {
    private let database: DynamoDB
    private let tableNameSuffix: String

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - database: The underlying Soto `DynamoDB` service.
    ///   - tableNameSuffix: Appended to every model's logical table name
    ///     before the request hits the wire. Use this to route an entire
    ///     deploy at a stage-specific table set. For example, pass
    ///     `"-prod"` so a model declared as `@Table("Hikes")` reads and
    ///     writes `"Hikes-prod"`. Default `""` is a no-op.
    public init(database: DynamoDB, tableNameSuffix: String = "") {
        self.database = database
        self.tableNameSuffix = tableNameSuffix
    }

    /// Applies the configured suffix to a logical table name. Public so
    /// callers building bespoke Soto requests can match the adapter's
    /// rewrite.
    public func resolveTableName(_ name: String) -> String {
        name + tableNameSuffix
    }

    public func execute<Model: DynamoModel>(
        _ input: DynamoQueries.QueryInput<Model>,
        logger: Logger
    ) async throws -> QueryPage<Model> {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            let output = try await self.database.query(
                input.toSotoQueryInput(tableNameOverride: resolved),
                logger: logger
            )
            let items = try (output.items ?? []).map { item in
                try DynamoDecoder.decode(Model.self, from: item)
            }
            let nextToken = output.lastEvaluatedKey.map { key in
                PaginationToken(key: key.mapValues { $0.toDynamoValue() })
            }
            return QueryPage(items: items, nextToken: nextToken)
        }
    }

    public func getItem<Model: DynamoModel>(
        _ input: DynamoQueries.GetItemInput<Model>,
        logger: Logger
    ) async throws -> Model? {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            let output = try await self.database.getItem(
                input.toSotoGetItemInput(tableNameOverride: resolved),
                logger: logger
            )
            guard let item = output.item else { return nil }
            return try DynamoDecoder.decode(Model.self, from: item)
        }
    }

    public func putItem<Model: DynamoModel>(
        _ input: DynamoQueries.PutItemInput<Model>,
        logger: Logger
    ) async throws {
        let resolved = resolveTableName(input.tableName)
        let sotoInput = try input.toSotoPutItemInput(tableNameOverride: resolved)
        try await translatingDynamoFailures {
            try await translatingConditionalCheckFailures(
                table: resolved,
                as: Model.self
            ) {
                _ = try await self.database.putItem(sotoInput, logger: logger)
            }
        }
    }

    public func updateItem<Model: DynamoModel>(
        _ input: DynamoQueries.UpdateInput<Model>,
        logger: Logger
    ) async throws {
        let resolved = resolveTableName(input.tableName)
        try await translatingDynamoFailures {
            try await translatingConditionalCheckFailures(
                table: resolved,
                as: Model.self
            ) {
                _ = try await self.database.updateItem(
                    input.toSotoUpdateItemInput(tableNameOverride: resolved),
                    logger: logger
                )
            }
        }
    }

    public func updateItemReturning<Model: DynamoModel>(
        _ input: DynamoQueries.UpdateReturning<Model>,
        logger: Logger
    ) async throws -> Model? {
        let resolved = resolveTableName(input.input.tableName)
        var result: Model?
        try await translatingDynamoFailures {
            try await translatingConditionalCheckFailures(
                table: resolved,
                as: Model.self
            ) {
                let output = try await self.database.updateItem(
                    input.toSotoUpdateItemInput(tableNameOverride: resolved),
                    logger: logger
                )
                if let attributes = output.attributes {
                    result = try? DynamoDecoder.decode(Model.self, from: attributes)
                }
            }
        }
        return result
    }

    public func deleteItem<Model: DynamoModel>(
        _ input: DynamoQueries.DeleteItemInput<Model>,
        logger: Logger
    ) async throws {
        let resolved = resolveTableName(input.tableName)
        try await translatingDynamoFailures {
            try await translatingConditionalCheckFailures(
                table: resolved,
                as: Model.self
            ) {
                _ = try await self.database.deleteItem(
                    input.toSotoDeleteItemInput(tableNameOverride: resolved),
                    logger: logger
                )
            }
        }
    }

    public func scan<Model: DynamoModel>(
        _ input: DynamoQueries.ScanInput<Model>,
        logger: Logger
    ) async throws -> QueryPage<Model> {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            let output = try await self.database.scan(
                input.toSotoScanInput(tableNameOverride: resolved),
                logger: logger
            )
            let items = try (output.items ?? []).map { item in
                try DynamoDecoder.decode(Model.self, from: item)
            }
            let nextToken = output.lastEvaluatedKey.map { key in
                PaginationToken(key: key.mapValues { $0.toDynamoValue() })
            }
            return QueryPage(items: items, nextToken: nextToken)
        }
    }

    public func count<Model: DynamoModel>(
        _ input: DynamoQueries.QueryInput<Model>,
        logger: Logger
    ) async throws -> CountPage {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            var withCount = input
            withCount.selectCountOnly = true
            let output = try await self.database.query(
                withCount.toSotoQueryInput(tableNameOverride: resolved),
                logger: logger
            )
            let nextToken = output.lastEvaluatedKey.map { key in
                PaginationToken(key: key.mapValues { $0.toDynamoValue() })
            }
            return CountPage(
                count: output.count.flatMap { Int(exactly: $0) } ?? 0,
                scannedCount: output.scannedCount.flatMap { Int(exactly: $0) } ?? 0,
                nextToken: nextToken
            )
        }
    }

    public func transactWrite(
        _ items: [DynamoQueries.TransactWriteItem],
        logger: Logger
    ) async throws {
        let sotoItems = try items.map { item -> DynamoDB.TransactWriteItem in
            let resolved = resolveTableName(item.tableName)
            switch item.kind {
            case .put(let model, let condition):
                let encoded = try DynamoEncoder.encode(model)
                return .put(DynamoDB.Put(
                    conditionExpression: condition?.expression,
                    expressionAttributeNames: nonEmpty(condition?.attributeNames),
                    expressionAttributeValues: nonEmpty(condition?.attributeValues),
                    item: encoded,
                    tableName: resolved
                ))
            case .update(let key, let updateExpr, let condition, let names, let values):
                return .update(DynamoDB.Update(
                    conditionExpression: condition?.expression,
                    expressionAttributeNames: names.isEmpty ? nil : names,
                    expressionAttributeValues: values.isEmpty
                        ? nil : values.mapValues { $0.toSotoAttributeValue() },
                    key: key.mapValues { $0.toSotoAttributeValue() },
                    tableName: resolved,
                    updateExpression: updateExpr
                ))
            case .delete(let key, let condition):
                return .delete(DynamoDB.Delete(
                    conditionExpression: condition?.expression,
                    expressionAttributeNames: nonEmpty(condition?.attributeNames),
                    expressionAttributeValues: nonEmpty(condition?.attributeValues),
                    key: key.mapValues { $0.toSotoAttributeValue() },
                    tableName: resolved
                ))
            case .conditionCheck(let key, let condition):
                return .conditionCheck(DynamoDB.ConditionCheck(
                    conditionExpression: condition.expression,
                    expressionAttributeNames: nonEmpty(condition.attributeNames),
                    expressionAttributeValues: nonEmpty(condition.attributeValues),
                    key: key.mapValues { $0.toSotoAttributeValue() },
                    tableName: resolved
                ))
            }
        }
        let soto = DynamoDB.TransactWriteItemsInput(transactItems: sotoItems)
        try await translatingDynamoFailures {
            try await translatingTransactionFailures {
                _ = try await self.database.transactWriteItems(soto, logger: logger)
            }
        }
    }

    public func transactGet(
        _ items: [DynamoQueries.TransactGetItem],
        logger: Logger
    ) async throws -> [(any DynamoModel)?] {
        // Lower each erased leg into a Soto `Get`, applying the configured table
        // suffix and projection. `sotoItems` lines up 1:1 with `items`, which
        // DynamoDB mirrors back in `responses`.
        let sotoItems = items.map { item -> DynamoDB.TransactGetItem in
            let resolved = self.resolveTableName(item.tableName)
            let (projection, names) = resolveProjection(
                attributes: item.projectionAttributes,
                existingNames: [:]
            )
            return DynamoDB.TransactGetItem(get: DynamoDB.Get(
                expressionAttributeNames: names.isEmpty ? nil : names,
                key: item.key.mapValues { $0.toSotoAttributeValue() },
                projectionExpression: projection,
                tableName: resolved
            ))
        }

        let output = try await translatingDynamoFailures {
            try await translatingTransactionFailures {
                try await self.database.transactGetItems(
                    DynamoDB.TransactGetItemsInput(transactItems: sotoItems),
                    logger: logger
                )
            }
        }

        // Decode the ordered responses via each leg's storage metatype. One
        // `ItemResponse` per requested item, in request order; a missing/empty
        // item decodes to `nil`.
        let responses = output.responses ?? []
        var results: [(any DynamoModel)?] = []
        for (index, item) in items.enumerated() {
            guard index < responses.count,
                  let raw = responses[index].item,
                  !raw.isEmpty
            else {
                results.append(nil)
                continue
            }
            results.append(try Self.decodeErased(item.modelType, from: raw))
        }
        return results
    }

    /// Decode a raw item into a dynamically-typed `DynamoModel` by opening the
    /// metatype existential into the generic `DynamoDecoder`.
    private static func decodeErased(
        _ type: any DynamoModel.Type,
        from item: [String: DynamoDB.AttributeValue]
    ) throws -> any DynamoModel {
        func open<M: DynamoModel>(_ concrete: M.Type) throws -> any DynamoModel {
            try DynamoDecoder.decode(M.self, from: item)
        }
        return try open(type)
    }

    public func batchWrite<Model: DynamoModel>(
        _ input: DynamoQueries.BatchWriteInput<Model>,
        logger: Logger
    ) async throws {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            let putRequests = try input.putItems.map { item -> DynamoDB.WriteRequest in
                let encoded = try DynamoEncoder.encode(item)
                return DynamoDB.WriteRequest(putRequest: DynamoDB.PutRequest(item: encoded))
            }
            let deleteRequests = input.deleteKeys.map { key in
                DynamoDB.WriteRequest(
                    deleteRequest: DynamoDB.DeleteRequest(
                        key: key.mapValues { $0.toSotoAttributeValue() }
                    )
                )
            }
            var pending = putRequests + deleteRequests
            while !pending.isEmpty {
                let soto = DynamoDB.BatchWriteItemInput(
                    requestItems: [resolved: pending]
                )
                let output = try await self.database.batchWriteItem(soto, logger: logger)
                pending = output.unprocessedItems?[resolved] ?? []
            }
        }
    }

    public func batchGet<Model: DynamoModel>(
        _ input: DynamoQueries.BatchGetInput<Model>,
        logger: Logger
    ) async throws -> [Model] {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            var pendingKeys = input.keys
            var collected: [Model] = []
            let (projection, names) = resolveProjection(
                attributes: input.projectionAttributes,
                existingNames: [:]
            )
            while !pendingKeys.isEmpty {
                let request = DynamoDB.KeysAndAttributes(
                    consistentRead: input.consistentRead ? true : nil,
                    expressionAttributeNames: names.isEmpty ? nil : names,
                    keys: pendingKeys.map { $0.mapValues { $0.toSotoAttributeValue() } },
                    projectionExpression: projection
                )
                let soto = DynamoDB.BatchGetItemInput(
                    requestItems: [resolved: request]
                )
                let output = try await self.database.batchGetItem(soto, logger: logger)
                if let items = output.responses?[resolved] {
                    for item in items {
                        let decoded = try DynamoDecoder.decode(Model.self, from: item)
                        collected.append(decoded)
                    }
                }
                if let unprocessed = output.unprocessedKeys?[resolved] {
                    pendingKeys = unprocessed.keys.map { rawKey in
                        rawKey.mapValues { $0.toDynamoValue() }
                    }
                } else {
                    pendingKeys = []
                }
            }
            return collected
        }
    }

    public func count<Model: DynamoModel>(
        _ input: DynamoQueries.ScanInput<Model>,
        logger: Logger
    ) async throws -> CountPage {
        try await translatingDynamoFailures {
            let resolved = self.resolveTableName(input.tableName)
            var withCount = input
            withCount.selectCountOnly = true
            let output = try await self.database.scan(
                withCount.toSotoScanInput(tableNameOverride: resolved),
                logger: logger
            )
            let nextToken = output.lastEvaluatedKey.map { key in
                PaginationToken(key: key.mapValues { $0.toDynamoValue() })
            }
            return CountPage(
                count: output.count.flatMap { Int(exactly: $0) } ?? 0,
                scannedCount: output.scannedCount.flatMap { Int(exactly: $0) } ?? 0,
                nextToken: nextToken
            )
        }
    }
}

// MARK: - DynamoValue ↔ Soto AttributeValue

extension DynamoValue {
    public func toSotoAttributeValue() -> DynamoDB.AttributeValue {
        switch self {
        case .string(let string):
            return .s(string)
        case .number(let number):
            return .n(number)
        case .bool(let bool):
            return .bool(bool)
        case .binary(let data):
            return .b(.data(data))
        case .null:
            return .null(true)
        case .list(let values):
            return .l(values.map { $0.toSotoAttributeValue() })
        case .map(let entries):
            return .m(entries.mapValues { $0.toSotoAttributeValue() })
        case .stringSet(let elements):
            return .ss(Array(elements))
        case .numberSet(let elements):
            return .ns(Array(elements))
        case .binarySet(let elements):
            return .bs(elements.map { .data($0) })
        }
    }
}

extension DynamoDB.AttributeValue {
    /// Reverse of `DynamoValue.toSotoAttributeValue()`. Used to lift
    /// `LastEvaluatedKey` back into a `PaginationToken`.
    func toDynamoValue() -> DynamoValue {
        switch self {
        case .s(let string): return .string(string)
        case .n(let number): return .number(number)
        case .bool(let bool): return .bool(bool)
        case .b(let base64):
            // `decoded()` returns `[UInt8]?`; `nil` means the wire value
            // wasn't valid base64, which would already have failed Soto's
            // own decode. Treat as a programmer error if we see it here.
            return .binary(Data(base64.decoded() ?? []))
        case .null: return .null
        case .l(let values): return .list(values.map { $0.toDynamoValue() })
        case .m(let entries): return .map(entries.mapValues { $0.toDynamoValue() })
        case .ss(let elements): return .stringSet(Set(elements))
        case .ns(let elements): return .numberSet(Set(elements))
        case .bs(let elements):
            return .binarySet(Set(elements.map { Data($0.decoded() ?? []) }))
        }
    }
}

// MARK: - Codable bridge
//
// Thin wrappers around Soto's `DynamoDBEncoder` / `DynamoDBDecoder`, which
// translate Swift `Codable` values directly to/from
// `DynamoDB.AttributeValue`: no JSON byte buffer, no `[String: Any]`
// boxing on the per-item path.
//
// Date strategy is pinned to `.secondsSince1970` so the Codable path
// agrees with the `DynamoEncodable` extension on `Date` in
// `DynamoQueries/Core/DynamoValue.swift`. Both write Unix-epoch seconds
// in a `.n` attribute, keeping values sortable in DynamoDB indexes and
// timezone-correct without further configuration.
//
// Binary fields:
// Soto's coder only special-cases `AWSBase64Data` (`.b` on the wire, native
// DynamoDB binary). Plain `Data` falls through to `Data.encode(to:)`,
// which writes each byte as an integer in a list (`.l([.n("…"), …])`),
// roughly 4× the wire size and not a proper binary type. Declare binary
// model fields as `AWSBase64Data` rather than `Data` to get native `.b`
// storage. The `DynamoEncodable` / `DynamoSizable` conformances below
// make `AWSBase64Data` a full drop-in replacement in the manual query
// DSL too.

enum DynamoEncoder {
    static func encode<T: Encodable>(_ value: T) throws -> [String: DynamoDB.AttributeValue] {
        let encoder = DynamoDBEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }
}

enum DynamoDecoder {
    static func decode<T: Decodable>(
        _ type: T.Type,
        from item: [String: DynamoDB.AttributeValue]
    ) throws -> T {
        let decoder = DynamoDBDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: item)
    }
}

// MARK: - AWSBase64Data ↔ DynamoQueries DSL
//
// `Data` is already `DynamoEncodable` / `DynamoSizable` (defined in
// `DynamoQueries/Core/DynamoValue.swift`). These conformances let
// `AWSBase64Data` stand in wherever `Data` would, so a model declared with
// `signature: AWSBase64Data?` can still write `Filter { $0.signature.size == 0 }`
// or compare against an attribute value via the same operators.

extension AWSBase64Data: DynamoQueries.DynamoEncodable {
    public func toDynamoValue() -> DynamoQueries.DynamoValue {
        .binary(Data(decoded() ?? []))
    }
}

extension AWSBase64Data: DynamoQueries.DynamoSizable {}
