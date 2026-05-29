/// A deferred read whose result has been transformed before delivery. Produced
/// by calling `.map` on the *collection / multi-shape* read inputs —
/// `BatchGetInput`, `QueryInput`, `ScanInput`, and `UpdateReturning`.
///
/// Single-item gets use `MappedGet` instead (see `TransactGet.swift`), because
/// a single get can also compose into a `TransactGet { ... }` block — these
/// inputs cannot, so they only need a standalone `.execute(using:)` terminal.
///
///     func roster(ids: [String]) throws -> MappedRead<[DomainHiker]> {
///         try Hiker.batchGet(partitionKeys: ids).map { $0.toDomain() }
///     }
public struct MappedRead<Output: Sendable>: Sendable {
    private let _execute: @Sendable (any DynamoClient) async throws -> Output

    init(_ execute: @Sendable @escaping (any DynamoClient) async throws -> Output) {
        self._execute = execute
    }

    public func execute(using client: any DynamoClient) async throws -> Output {
        try await _execute(client)
    }
}

// MARK: - BatchGetInput

extension BatchGetInput {
    /// Transform every found item before delivery.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) -> Output
    ) -> MappedRead<[Output]> {
        MappedRead { try await self.execute(using: $0).map(transform) }
    }
}

// MARK: - QueryInput

extension QueryInput {
    /// Transform items in each page before delivery. The `nextToken` is
    /// preserved so pagination works identically on the mapped result.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) -> Output
    ) -> MappedRead<QueryPage<Output>> {
        MappedRead { try await self.execute(using: $0).map(transform) }
    }
}

// MARK: - ScanInput

extension ScanInput {
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) -> Output
    ) -> MappedRead<QueryPage<Output>> {
        MappedRead { try await self.execute(using: $0).map(transform) }
    }
}

// MARK: - UpdateReturning

extension UpdateReturning {
    /// Transform the returned item (old or new value) before delivery. `nil`
    /// passes through when DynamoDB returns no attributes for the chosen
    /// `returnValues` mode.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) -> Output
    ) -> MappedRead<Output?> {
        MappedRead { try await self.execute(using: $0).map(transform) }
    }
}
