import DynamoQueries
import Logging
import SotoDynamoDB

// MARK: - Schema → CreateTable
//
// `@Table` and `@Index` capture everything CreateTable needs (key shapes plus
// each key attribute's scalar type), so the adapter can create a table
// straight from the model. The main consumer is test setup against DynamoDB
// Local, where this replaces hand-written schema definitions that would
// otherwise drift from the model.

extension DynamoQueries.DynamoKeyType {
    public func toSotoScalarAttributeType() -> DynamoDB.ScalarAttributeType {
        switch self {
        case .string: return .s
        case .number: return .n
        case .binary: return .b
        }
    }
}

extension DynamoModel {
    /// Builds the `CreateTable` request matching the schema declared via
    /// `@Table` / `@Index`. Every GSI projects all attributes.
    ///
    /// Pass `tableName` to override the model's wire name (e.g. a unique
    /// per-test suffix). The default `.payPerRequest` billing mode keeps the
    /// request valid without per-index throughput settings.
    public static func createTableInput(
        tableName: String? = nil,
        billingMode: DynamoDB.BillingMode = .payPerRequest
    ) -> DynamoDB.CreateTableInput {
        var keyAttributes = [_table.partitionKey]
        if let sortKey = _table.sortKey {
            keyAttributes.append(sortKey)
        }
        keyAttributes += indexes.flatMap { $0.partitionKeys + $0.sortKeys }

        // The same attribute may key several indexes; AttributeDefinitions
        // wants it once. Types can't conflict since each name resolves to a
        // single property.
        var seen = Set<String>()
        let attributeDefinitions = keyAttributes.compactMap { attribute -> DynamoDB.AttributeDefinition? in
            guard seen.insert(attribute.name).inserted else { return nil }
            return .init(
                attributeName: attribute.name,
                attributeType: attribute.type.toSotoScalarAttributeType()
            )
        }

        var keySchema: [DynamoDB.KeySchemaElement] = [
            .init(attributeName: _table.partitionKey.name, keyType: .hash)
        ]
        if let sortKey = _table.sortKey {
            keySchema.append(.init(attributeName: sortKey.name, keyType: .range))
        }

        let secondaryIndexes = indexes.map { index in
            DynamoDB.GlobalSecondaryIndex(
                indexName: index.name,
                keySchema: index.partitionKeys.map { .init(attributeName: $0.name, keyType: .hash) }
                    + index.sortKeys.map { .init(attributeName: $0.name, keyType: .range) },
                projection: .init(projectionType: .all)
            )
        }

        return DynamoDB.CreateTableInput(
            attributeDefinitions: attributeDefinitions,
            billingMode: billingMode,
            globalSecondaryIndexes: secondaryIndexes.isEmpty ? nil : secondaryIndexes,
            keySchema: keySchema,
            tableName: tableName ?? _table.name
        )
    }
}

extension DynamoDB {
    /// Creates the model's table from its macro-declared schema.
    @discardableResult
    public func createTable(
        for model: (some DynamoModel).Type,
        tableName: String? = nil,
        billingMode: BillingMode = .payPerRequest,
        logger: Logger = AWSClient.loggingDisabled
    ) async throws -> CreateTableOutput {
        try await createTable(
            model.createTableInput(tableName: tableName, billingMode: billingMode),
            logger: logger
        )
    }
}
