/// A compiled DynamoDB Query request, parameterized by the model it returns.
///
/// `QueryInput` is built by `Model.query { Key { ... } }` and configured
/// through chainable modifiers (`.usingIndex(_:)`, `.limit(_:)`, `.consistentRead()`,
/// `.scanIndexForward(_:)`, `.startToken(_:)`). Calling `.execute(using:)` is
/// what fires the request.
public struct QueryInput<Model: DynamoModel>: Sendable {
    public let tableName: String
    public var indexName: String?
    public let keyConditionExpression: String
    public let filterExpression: String?
    public let expressionAttributeNames: [String: String]
    public let expressionAttributeValues: [String: DynamoValue]
    public var limit: Int?
    public var exclusiveStartKey: [String: DynamoValue]?
    public var consistentRead: Bool
    public var scanIndexForward: Bool?
    /// Attribute names to project into the response. The Soto adapter is
    /// responsible for safely placeholdering these (some attribute names are
    /// DynamoDB reserved words). `nil` means "fetch the whole item".
    public var projectionAttributes: [String]?
    /// When `true`, the request asks DynamoDB for `Select: COUNT` — the
    /// server returns counts only, no items. Set internally by
    /// `.count(using:)`; users shouldn't need to flip this directly.
    public var selectCountOnly: Bool

    public init(
        tableName: String,
        indexName: String? = nil,
        keyConditionExpression: String,
        filterExpression: String? = nil,
        expressionAttributeNames: [String: String] = [:],
        expressionAttributeValues: [String: DynamoValue] = [:],
        limit: Int? = nil,
        exclusiveStartKey: [String: DynamoValue]? = nil,
        consistentRead: Bool = false,
        scanIndexForward: Bool? = nil,
        projectionAttributes: [String]? = nil,
        selectCountOnly: Bool = false
    ) {
        self.tableName = tableName
        self.indexName = indexName
        self.keyConditionExpression = keyConditionExpression
        self.filterExpression = filterExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
        self.limit = limit
        self.exclusiveStartKey = exclusiveStartKey
        self.consistentRead = consistentRead
        self.scanIndexForward = scanIndexForward
        self.projectionAttributes = projectionAttributes
        self.selectCountOnly = selectCountOnly
    }
}

// MARK: - Modifiers

extension QueryInput {
    /// Run the query against a secondary index instead of the base table.
    public func usingIndex(_ index: Index<Model>) -> Self {
        var copy = self
        copy.indexName = index.name
        return copy
    }

    /// Cap the per-request `Limit` DynamoDB applies. Has no effect on
    /// `executeAll(using:)` beyond shaping page size.
    public func limit(_ value: Int) -> Self {
        var copy = self
        copy.limit = value
        return copy
    }

    /// Resume from a prior page's `nextToken`. Pass `nil` to start fresh.
    public func startToken(_ token: PaginationToken?) -> Self {
        var copy = self
        copy.exclusiveStartKey = token?.key
        return copy
    }

    /// Request a strongly consistent read. DynamoDB's default is eventually
    /// consistent; flipping this on doubles read-capacity cost. Not allowed on
    /// global secondary indexes — DynamoDB will reject the request at runtime.
    public func consistentRead(_ value: Bool = true) -> Self {
        var copy = self
        copy.consistentRead = value
        return copy
    }

    /// `true` walks the sort key in ascending order (DynamoDB's default);
    /// `false` walks it in descending order.
    public func scanIndexForward(_ forward: Bool) -> Self {
        var copy = self
        copy.scanIndexForward = forward
        return copy
    }

    /// Restrict the response to the listed attributes, saving bandwidth.
    /// Caveat: if the projection drops an attribute the model declares as
    /// non-optional, decoding the response will fail — the adapter doesn't
    /// know which fields you need. Project only the attributes your call
    /// site actually consumes, or model them as optional.
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

extension QueryInput {
    /// Run a single page of the query.
    public func execute(using client: any DynamoClient) async throws -> QueryPage<Model> {
        try await client.execute(self)
    }

    /// Stream the query as an `AsyncSequence` of pages. Each `next()` fires
    /// one DynamoDB Query request — backpressure is the consumer's: pages are
    /// only fetched as the loop iterates. The sequence finishes after the
    /// page whose `nextToken` is `nil`.
    ///
    ///     for try await page in MyModel.query { Key { ... } }.pages(using: client) {
    ///         for item in page.items { ... }
    ///     }
    public func pages(using client: any DynamoClient) -> QueryPageSequence<Model> {
        QueryPageSequence(input: self, client: client)
    }

    /// Run the query and transparently paginate through every page, returning
    /// a flat array. Buffers every item in memory; for unbounded result sets
    /// reach for `pages(using:)` instead and process page-by-page.
    public func executeAll(using client: any DynamoClient) async throws -> [Model] {
        var allItems: [Model] = []
        for try await page in pages(using: client) {
            allItems.append(contentsOf: page.items)
        }
        return allItems
    }

    /// Count matching items without retrieving them — `Select: COUNT` on the
    /// wire. Auto-paginates through every page and returns the sum. Cheaper
    /// than `executeAll(...).count` because no item bytes cross the wire,
    /// though DynamoDB still bills the same RCU for items the filter looked
    /// at (if any).
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

// MARK: - QueryPageSequence

/// `AsyncSequence` of `QueryPage`s produced by `QueryInput.pages(using:)`.
/// Each iteration step issues exactly one DynamoDB request.
public struct QueryPageSequence<Model: DynamoModel>: AsyncSequence {
    public typealias Element = QueryPage<Model>

    let input: QueryInput<Model>
    let client: any DynamoClient

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(input: input, client: client)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var input: QueryInput<Model>
        let client: any DynamoClient
        var finished = false

        public mutating func next() async throws -> QueryPage<Model>? {
            if finished { return nil }
            let page = try await client.execute(input)
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

public enum QueryInputBuilder {
    public static func build<Model: DynamoModel>(
        for type: Model.Type,
        keyConditions: [KeyCondition],
        filterConditions: [Expression] = []
    ) -> QueryInput<Model> {
        var allocator = PlaceholderAllocator()
        let keyExpressions = keyConditions.map(\.expression)
        let keyExpression = ExpressionCompiler.compile(keyExpressions, allocator: &allocator)
        let filterExpression = filterConditions.isEmpty
            ? nil
            : ExpressionCompiler.compile(filterConditions, allocator: &allocator)

        return QueryInput<Model>(
            tableName: Model._table.name,
            keyConditionExpression: keyExpression,
            filterExpression: filterExpression,
            expressionAttributeNames: allocator.attributeNames,
            expressionAttributeValues: allocator.attributeValues
        )
    }
}
