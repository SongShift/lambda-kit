/// A compiled DynamoDB Scan request, parameterized by the model it returns.
///
/// `ScanInput` is `QueryInput` minus the key-condition expression. DynamoDB
/// applies the filter *after* it has read the page from disk, so a filtered
/// scan still bills for the unfiltered read — a heavy hint that scans are a
/// last resort. Reach for `Query` whenever the access pattern lets you
/// constrain the partition key.
public struct ScanInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public var indexName: String?
    public let filterExpression: String?
    public let expressionAttributeNames: [String: String]
    public let expressionAttributeValues: [String: DynamoValue]
    public var limit: Int?
    public var exclusiveStartKey: [String: DynamoValue]?
    public var consistentRead: Bool
    public var projectionAttributes: [String]?
    public var selectCountOnly: Bool

    public init(
        tableName: String,
        indexName: String? = nil,
        filterExpression: String? = nil,
        expressionAttributeNames: [String: String] = [:],
        expressionAttributeValues: [String: DynamoValue] = [:],
        limit: Int? = nil,
        exclusiveStartKey: [String: DynamoValue]? = nil,
        consistentRead: Bool = false,
        projectionAttributes: [String]? = nil,
        selectCountOnly: Bool = false
    ) {
        self.tableName = tableName
        self.indexName = indexName
        self.filterExpression = filterExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
        self.limit = limit
        self.exclusiveStartKey = exclusiveStartKey
        self.consistentRead = consistentRead
        self.projectionAttributes = projectionAttributes
        self.selectCountOnly = selectCountOnly
    }
}

// MARK: - Modifiers

extension ScanInput {
    public func usingIndex(_ index: Index<Model>) -> Self {
        var copy = self
        copy.indexName = index.name
        return copy
    }

    public func limit(_ value: Int) -> Self {
        var copy = self
        copy.limit = value
        return copy
    }

    public func startToken(_ token: PaginationToken?) -> Self {
        var copy = self
        copy.exclusiveStartKey = token?.key
        return copy
    }

    /// Strongly consistent scan. Same caveats as `QueryInput.consistentRead`:
    /// double the read cost, and not allowed on a global secondary index.
    public func consistentRead(_ value: Bool = true) -> Self {
        var copy = self
        copy.consistentRead = value
        return copy
    }

    /// Restrict the response to the listed attributes. Same caveats as
    /// `QueryInput.project`.
    public func project(_ attrs: any AttributeReference...) -> Self {
        project(attrs)
    }

    public func project(_ attrs: [any AttributeReference]) -> Self {
        var copy = self
        copy.projectionAttributes = attrs.map(\.name)
        return copy
    }
}

// MARK: - Execute

extension ScanInput {
    public func execute(using client: any DynamoClient) async throws -> QueryPage<Model> {
        try await client.scan(self)
    }

    /// Stream the scan as an `AsyncSequence` of pages. Each `next()` fires
    /// one DynamoDB Scan request — backpressure is the consumer's. Scans bill
    /// for every item read regardless of filter, so iterating a large table
    /// is expensive even if you stop early.
    public func pages(using client: any DynamoClient) -> ScanPageSequence<Model> {
        ScanPageSequence(input: self, client: client)
    }

    /// Auto-paginating scan that returns every matching item. Buffers every
    /// item in memory; for unbounded result sets reach for `pages(using:)`
    /// instead.
    public func executeAll(using client: any DynamoClient) async throws -> [Model] {
        var allItems: [Model] = []
        for try await page in pages(using: client) {
            allItems.append(contentsOf: page.items)
        }
        return allItems
    }

    /// Count matching items via `Select: COUNT`. Same caveat as
    /// `QueryInput.count` — the scan still bills full RCU for items it
    /// touched.
    public func count(using client: any DynamoClient) async throws -> Int {
        var input = self
        input.selectCountOnly = true
        var total = 0
        var token: PaginationToken? = nil
        repeat {
            input.exclusiveStartKey = token?.key
            let page = try await client.count(input)
            total += page.count
            token = page.nextToken
        } while token != nil
        return total
    }
}

// MARK: - ScanPageSequence

public struct ScanPageSequence<Model: DynamoModel>: AsyncSequence {
    public typealias Element = QueryPage<Model>

    let input: ScanInput<Model>
    let client: any DynamoClient

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(input: input, client: client)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var input: ScanInput<Model>
        let client: any DynamoClient
        var finished = false

        public mutating func next() async throws -> QueryPage<Model>? {
            if finished { return nil }
            let page = try await client.scan(input)
            if let token = page.nextToken {
                input = input.startToken(token)
            } else {
                finished = true
            }
            return page
        }
    }
}

// MARK: - Builder

public enum ScanInputBuilder {
    public static func build<Model: DynamoModel>(
        for type: Model.Type,
        filterConditions: [Expression] = []
    ) -> ScanInput<Model> {
        var allocator = PlaceholderAllocator()
        let filterExpression = filterConditions.isEmpty
            ? nil
            : ExpressionCompiler.compile(filterConditions, allocator: &allocator)
        return ScanInput<Model>(
            tableName: Model._table.name,
            filterExpression: filterExpression,
            expressionAttributeNames: allocator.attributeNames,
            expressionAttributeValues: allocator.attributeValues
        )
    }
}
