import Foundation
import DynamoQueries

/// Captures every DSL-built input, prints what the wire-level request looks
/// like, and hands back canned responses. Real adapters live in
/// `DynamoQueriesSoto`.
actor RecordingClient: DynamoClient {
    func execute<Model: DynamoModel>(_ input: QueryInput<Model>) async throws -> QueryPage<Model> {
        print("""
        Query \(input.tableName)\(input.indexName.map { " on \($0)" } ?? "")
            keyCondition: \(input.keyConditionExpression)
            filter:       \(input.filterExpression ?? "(none)")
            names:        \(input.expressionAttributeNames)
            values:       \(input.expressionAttributeValues)
        """)
        return QueryPage(items: [], nextToken: nil)
    }

    func getItem<Model: DynamoModel>(_ input: GetItemInput<Model>) async throws -> Model? {
        print("GetItem \(input.tableName) key=\(input.key)")
        return nil
    }

    func putItem<Model: DynamoModel>(_ input: PutItemInput<Model>) async throws {
        print("""
        PutItem \(input.tableName)
            condition: \(input.conditionExpression ?? "(none)")
        """)
    }

    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>) async throws {
        print("""
        UpdateItem \(input.tableName)
            update:    \(input.updateExpression)
            condition: \(input.conditionExpression ?? "(none)")
        """)
    }

    func updateItemReturning<Model: DynamoModel>(_ input: UpdateReturning<Model>) async throws -> Model? {
        try await updateItem(input.input)
        return nil
    }

    func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>) async throws {
        print("DeleteItem \(input.tableName) key=\(input.key)")
    }

    func scan<Model: DynamoModel>(_ input: ScanInput<Model>) async throws -> QueryPage<Model> {
        print("Scan \(input.tableName) filter=\(input.filterExpression ?? "(none)")")
        return QueryPage(items: [], nextToken: nil)
    }

    func count<Model: DynamoModel>(_ input: QueryInput<Model>) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    func count<Model: DynamoModel>(_ input: ScanInput<Model>) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }

    func batchGet<Model: DynamoModel>(_ input: BatchGetInput<Model>) async throws -> [Model] {
        print("BatchGet \(input.tableName) keys=\(input.keys.count)")
        return []
    }

    func batchWrite<Model: DynamoModel>(_ input: BatchWriteInput<Model>) async throws {
        print("BatchWrite \(input.tableName) puts=\(input.putItems.count) deletes=\(input.deleteKeys.count)")
    }

    func transactWrite(_ items: [TransactWriteItem]) async throws {
        print("TransactWrite legs=\(items.count)")
    }

    func transactGet(
        _ items: [TransactGetItem]
    ) async throws -> [(any DynamoModel)?] {
        print("TransactGet legs=\(items.count) tables=\(items.map(\.tableName))")
        return items.map { _ in nil }
    }
}
