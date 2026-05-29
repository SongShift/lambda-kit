/// A read transaction — an atomic, serializable snapshot of up to 100 items,
/// each addressed by primary key, that may span tables and models.
///
/// Where `batchGet` reads a single table, may be eventually consistent, and
/// returns the items it found in no guaranteed order, a `TransactGetInput`
/// reads every leg inside one DynamoDB `TransactGetItems` call: the reads see
/// a single consistent point in time, and the result is a *typed tuple* in the
/// same order the legs were declared — `nil` for any leg whose item was not
/// found.
///
///     let (hiker, hike, log) = try await TransactGet {
///         try Hiker.get(partitionKey: "hiker-1")
///         try Hike.get(partitionKey: "hiker-1", sortKey: "2026-001")
///         try TrailLog.get(partitionKey: "log-9")
///     }
///     .execute(using: client)
///     // hiker: Hiker?, hike: Hike?, log: TrailLog?
///
/// Each leg is an ordinary `GetItemInput` built via `Model.get(...)`, so
/// `.project(_:)` works per leg. `.consistentRead()` is *accepted but ignored*
/// — `TransactGetItems` is always serializable and exposes no per-item
/// consistency knob.
///
/// DynamoDB requires between 1 and 100 legs; outside that range the request is
/// rejected on the wire. A canceled read transaction surfaces as
/// `TransactionCanceled`.
public struct TransactGetInput<each Model: DynamoModel>: Sendable {
    public let gets: (repeat GetItemInput<each Model>)

    /// Build from an explicit, comma-separated list of `GetItemInput` legs.
    public init(_ gets: repeat GetItemInput<each Model>) {
        self.gets = (repeat each gets)
    }

    /// Build the legs with the `TransactGet { ... }` closure DSL.
    public init(
        @TransactGetBuilder _ build: () throws -> (repeat GetItemInput<each Model>)
    ) rethrows {
        self.gets = try build()
    }
}

// MARK: - Execute

extension TransactGetInput {
    /// Run the read transaction. Returns one optional per leg, in declaration
    /// order; a leg whose key matched no item decodes to `nil`.
    public func execute(
        using client: any DynamoClient
    ) async throws -> (repeat (each Model)?) {
        try await client.transactGet(repeat each gets)
    }
}

// MARK: - Result builder

/// Result builder backing `TransactGetInput`. Only `buildBlock` is provided:
/// the result is a fixed-arity, statically-typed tuple, so control flow that
/// would change the number or types of legs (`if`, `for`, `switch`) can't be
/// expressed — and shouldn't be, since the caller binds the result positionally.
@resultBuilder
public enum TransactGetBuilder {
    public static func buildBlock<each Model: DynamoModel>(
        _ gets: repeat GetItemInput<each Model>
    ) -> (repeat GetItemInput<each Model>) {
        (repeat each gets)
    }
}

/// Spelling that mirrors the `TransactWriteInput { ... }` write side at the
/// call site: `TransactGet { ... }`.
public typealias TransactGet<each Model: DynamoModel> = TransactGetInput<repeat each Model>
