import Logging

/// Mapped read inputs: the result of calling `.map` on a *collection / paged*
/// read (`QueryInput`, `ScanInput`, `BatchGetInput`) or on `UpdateReturning`.
///
/// Each type stores `(input, transform)` and **forwards its source's full
/// terminal surface** with the transform applied, so a mapped query still has
/// `executeAll`, `pages`, and `count`, and a mapped scan still returns a real
/// `QueryPage<Output>`. Nothing about the underlying operation is hidden; only
/// the delivered element type changes. This mirrors `MappedGet` (see
/// `TransactGet.swift`), which does the same for single-item gets.
///
///     func recent() -> MappedScan<Hike, DomainHike> {
///         Hike.scan { $0.status == "in_progress" }.map { $0.toDomain() }
///     }
///     let all = try await repo.recent().executeAll(using: client)   // [DomainHike]
///
/// Single-item gets use `MappedGet` instead, because a get can *also* compose
/// into a `TransactGet { ... }` block (it conforms to `Read`); these
/// collection reads cannot, so they only need their standalone terminals.

// MARK: - Mapped paged page sequence

/// An `AsyncSequence` of `QueryPage<Output>` produced by mapping a transform
/// over an underlying page sequence (`QueryPageSequence` / `ScanPageSequence`).
/// Backpressure is preserved: the transform runs only as each page is pulled.
public struct MappedPageSequence<
    Model: DynamoModel,
    Output: Sendable,
    Base: AsyncSequence
>: AsyncSequence where Base.Element == QueryPage<Model> {
    public typealias Element = QueryPage<Output>

    let base: Base
    let transform: @Sendable (Model) throws -> Output

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), transform: transform)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let transform: @Sendable (Model) throws -> Output

        public mutating func next() async throws -> QueryPage<Output>? {
            guard let page = try await base.next() else { return nil }
            return try page.map(transform)
        }
    }
}

// MARK: - MappedQuery

/// A `QueryInput` with a transform applied to every item. Exposes the same
/// terminals as `QueryInput` (`execute`, `pages`, `executeAll`, `count`),
/// each yielding `Output` instead of `Model`.
public struct MappedQuery<Model: DynamoModel, Output: Sendable>: Sendable {
    let input: QueryInput<Model>
    let transform: @Sendable (Model) throws -> Output

    /// One page, items transformed.
    public func execute(
        using client: any DynamoClient,
        logger: Logger
    ) async throws -> QueryPage<Output> {
        try await input.execute(using: client, logger: logger).map(transform)
    }

    /// Stream pages lazily; each page's items are transformed.
    public func pages(
        using client: any DynamoClient,
        logger: Logger
    ) -> MappedPageSequence<Model, Output, QueryPageSequence<Model>> {
        MappedPageSequence(base: input.pages(using: client, logger: logger), transform: transform)
    }

    /// Auto-paginate and transform every item into a flat array.
    public func executeAll(
        using client: any DynamoClient,
        logger: Logger
    ) async throws -> [Output] {
        try await input.executeAll(using: client, logger: logger).map(transform)
    }

    /// Count matching items. The transform is irrelevant to a `Select: COUNT`
    /// request, so this is identical to the unmapped `count`.
    public func count(using client: any DynamoClient, logger: Logger) async throws -> Int {
        try await input.count(using: client, logger: logger)
    }

    /// Chain another transform.
    public func map<Next: Sendable>(
        _ next: @Sendable @escaping (Output) throws -> Next
    ) -> MappedQuery<Model, Next> {
        MappedQuery<Model, Next>(input: input) { try next(self.transform($0)) }
    }
}

extension QueryInput {
    /// Transform every item before delivery. Returns a `MappedQuery` that keeps
    /// the full query terminal surface (`execute` / `pages` / `executeAll` /
    /// `count`), yielding the mapped type.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) throws -> Output
    ) -> MappedQuery<Model, Output> {
        MappedQuery(input: self, transform: transform)
    }
}

// MARK: - MappedScan

/// A `ScanInput` with a transform applied to every item. Same terminal surface
/// as `ScanInput`, yielding `Output`.
public struct MappedScan<Model: DynamoModel, Output: Sendable>: Sendable {
    let input: ScanInput<Model>
    let transform: @Sendable (Model) throws -> Output

    public func execute(
        using client: any DynamoClient,
        logger: Logger
    ) async throws -> QueryPage<Output> {
        try await input.execute(using: client, logger: logger).map(transform)
    }

    public func pages(
        using client: any DynamoClient,
        logger: Logger
    ) -> MappedPageSequence<Model, Output, ScanPageSequence<Model>> {
        MappedPageSequence(base: input.pages(using: client, logger: logger), transform: transform)
    }

    public func executeAll(
        using client: any DynamoClient,
        logger: Logger
    ) async throws -> [Output] {
        try await input.executeAll(using: client, logger: logger).map(transform)
    }

    public func count(using client: any DynamoClient, logger: Logger) async throws -> Int {
        try await input.count(using: client, logger: logger)
    }

    public func map<Next: Sendable>(
        _ next: @Sendable @escaping (Output) throws -> Next
    ) -> MappedScan<Model, Next> {
        MappedScan<Model, Next>(input: input) { try next(self.transform($0)) }
    }
}

extension ScanInput {
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) throws -> Output
    ) -> MappedScan<Model, Output> {
        MappedScan(input: self, transform: transform)
    }
}

// MARK: - MappedBatchGet

/// A `BatchGetInput` with a transform applied to every found item. Mirrors
/// `BatchGetInput`'s single terminal: `execute` returns `[Output]` (still in
/// no guaranteed order).
public struct MappedBatchGet<Model: DynamoModel, Output: Sendable>: Sendable {
    let input: BatchGetInput<Model>
    let transform: @Sendable (Model) throws -> Output

    public func execute(using client: any DynamoClient, logger: Logger) async throws -> [Output] {
        try await input.execute(using: client, logger: logger).map(transform)
    }

    public func map<Next: Sendable>(
        _ next: @Sendable @escaping (Output) throws -> Next
    ) -> MappedBatchGet<Model, Next> {
        MappedBatchGet<Model, Next>(input: input) { try next(self.transform($0)) }
    }
}

extension BatchGetInput {
    /// Transform every found item before delivery.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) throws -> Output
    ) -> MappedBatchGet<Model, Output> {
        MappedBatchGet(input: self, transform: transform)
    }
}

// MARK: - MappedUpdateReturning

/// An `UpdateReturning` with a transform applied to the returned item. `execute`
/// yields `Output?`. `nil` passes through when DynamoDB returns no attributes
/// for the chosen `returnValues` mode.
public struct MappedUpdateReturning<Model: DynamoModel, Output: Sendable>: Sendable {
    let input: UpdateReturning<Model>
    let transform: @Sendable (Model) throws -> Output

    public func execute(
        using client: any DynamoClient,
        logger: Logger = .dynamoQueriesDisabled
    ) async throws -> Output? {
        try await input.execute(using: client, logger: logger).map(transform)
    }

    public func map<Next: Sendable>(
        _ next: @Sendable @escaping (Output) throws -> Next
    ) -> MappedUpdateReturning<Model, Next> {
        MappedUpdateReturning<Model, Next>(input: input) { try next(self.transform($0)) }
    }
}

extension UpdateReturning {
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) throws -> Output
    ) -> MappedUpdateReturning<Model, Output> {
        MappedUpdateReturning(input: self, transform: transform)
    }
}
