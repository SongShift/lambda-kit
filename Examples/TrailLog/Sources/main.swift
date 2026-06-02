//
//  TrailLogDemo
//
//  A complete Lambda-shaped service using both libraries together.

import AWSLambdaEvents
import AWSLambdaRuntime
import DynamoQueries
import Foundation
import Logging
import Routing

// MARK: - Fake DynamoDB client

/// Stores items in an in-memory dictionary keyed by `(table, primary key)`.
/// Implements just enough of `DynamoClient` to keep the demo working without
/// AWS. Production code should reach for `SotoDynamoClient`.
actor FakeDynamoClient: DynamoClient {
    private var items: [String: [String: Data]] = [:]

    private static func keyString(_ key: [String: DynamoValue]) -> String {
        key.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
    }

    func execute<Model: DynamoModel>(
        _ input: QueryInput<Model>,
        logger _: Logger
    ) async throws -> QueryPage<Model> {
        QueryPage(items: [], nextToken: nil)
    }

    func getItem<Model: DynamoModel>(
        _ input: GetItemInput<Model>,
        logger _: Logger
    ) async throws -> Model? {
        guard let table = items[input.tableName],
              let data = table[Self.keyString(input.key)]
        else { return nil }
        return try JSONDecoder().decode(Model.self, from: data)
    }

    func putItem<Model: DynamoModel>(_ input: PutItemInput<Model>, logger _: Logger) async throws {
        let data = try JSONEncoder().encode(input.item)
        let key: [String: DynamoValue] = [
            Model._table.partitionKey: .string(extractPK(of: input.item))
        ]
        items[input.tableName, default: [:]][Self.keyString(key)] = data
    }

    func updateItem<Model: DynamoModel>(_ input: UpdateInput<Model>, logger _: Logger) async throws {}
    func updateItemReturning<Model: DynamoModel>(
        _ input: UpdateReturning<Model>,
        logger _: Logger
    ) async throws -> Model? { nil }
    func deleteItem<Model: DynamoModel>(_ input: DeleteItemInput<Model>, logger _: Logger) async throws {}
    func scan<Model: DynamoModel>(
        _ input: ScanInput<Model>,
        logger _: Logger
    ) async throws -> QueryPage<Model> {
        QueryPage(items: [], nextToken: nil)
    }
    func count<Model: DynamoModel>(_ input: QueryInput<Model>, logger _: Logger) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }
    func count<Model: DynamoModel>(_ input: ScanInput<Model>, logger _: Logger) async throws -> CountPage {
        CountPage(count: 0, scannedCount: 0, nextToken: nil)
    }
    func batchGet<Model: DynamoModel>(_ input: BatchGetInput<Model>, logger _: Logger) async throws -> [Model] { [] }
    func batchWrite<Model: DynamoModel>(_ input: BatchWriteInput<Model>, logger _: Logger) async throws {}
    func transactWrite(_ items: [TransactWriteItem], logger _: Logger) async throws {}
    func transactGet(
        _ items: [TransactGetItem],
        logger _: Logger
    ) async throws -> [(any DynamoModel)?] {
        items.map { _ in nil }
    }

    /// Best-effort partition-key extraction for the fake's storage map. Real
    /// adapters use `DynamoEncoder` for this; we cheat with `Mirror`.
    private func extractPK<Model: DynamoModel>(of item: Model) -> String {
        let pkName = Model._table.partitionKey
        let mirror = Mirror(reflecting: item)
        for child in mirror.children where child.label == pkName {
            return "\(child.value)"
        }
        return UUID().uuidString
    }
}

// MARK: - Build the router (cold-start cost only)

let database: any DynamoClient = FakeDynamoClient()
let routerBuilder = HTTPRouterBuilder()
registerRoutes(on: routerBuilder, using: database)
let router = routerBuilder.build()

// MARK: - Lambda runtime

let runtime = LambdaRuntime {
    (event: APIGatewayV2Request, context: LambdaContext) async -> APIGatewayV2Response in
    let response = await router.handle(HTTPRequest(event: event), logger: context.logger)
    return APIGatewayV2Response(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body
    )
}

try await runtime.run()
