/// A primary-key read leg that can be composed into a `TransactGet { ... }`
/// block *or* executed on its own. Both a plain `GetItemInput` and a mapped
/// `MappedGet` conform, so there is no difference between a "raw" and a
/// "mapped" leg at a call site — only the delivered `Output` type differs.
///
/// `Storage` is the on-table model the adapter decodes; `Output` is what the
/// caller actually receives. For an un-mapped get the two coincide.
public protocol ReadLeg<Output>: Sendable {
    associatedtype Storage: DynamoModel
    associatedtype Output: Sendable

    /// The underlying single-item request handed to the transport.
    var getItemInput: GetItemInput<Storage> { get }

    /// Convert a decoded storage item into the delivered output. Called only
    /// for a present item — a missing key never reaches here.
    func transform(_ storage: Storage) -> Output
}

// MARK: - GetItemInput as an identity leg

extension GetItemInput: ReadLeg {
    public var getItemInput: GetItemInput<Model> { self }
    public func transform(_ storage: Model) -> Model { storage }
}

// MARK: - MappedGet

/// A `GetItemInput` with a transform applied to its result. Produced by
/// `GetItemInput.map`. Conforms to `ReadLeg`, so it composes in a
/// `TransactGet { ... }` block exactly like a raw get, and also runs standalone
/// via `execute(using:)`.
public struct MappedGet<Storage: DynamoModel, Output: Sendable>: ReadLeg {
    public let getItemInput: GetItemInput<Storage>
    private let _transform: @Sendable (Storage) -> Output

    init(
        getItemInput: GetItemInput<Storage>,
        transform: @Sendable @escaping (Storage) -> Output
    ) {
        self.getItemInput = getItemInput
        self._transform = transform
    }

    public func transform(_ storage: Storage) -> Output { _transform(storage) }

    /// Chain another transform.
    public func map<Next: Sendable>(
        _ next: @Sendable @escaping (Output) -> Next
    ) -> MappedGet<Storage, Next> {
        MappedGet<Storage, Next>(getItemInput: getItemInput) { next(self._transform($0)) }
    }

    /// Execute this single read on its own. Returns `nil` for a missing key;
    /// the transform is applied only to a present item.
    public func execute(using client: any DynamoClient) async throws -> Output? {
        try await getItemInput.execute(using: client).map(_transform)
    }
}

extension GetItemInput {
    /// Transform the item (if found) before delivery. Returns a `MappedGet`
    /// leg — usable both standalone and inside a `TransactGet { ... }` block.
    /// The closure is not called for a missing key.
    public func map<Output: Sendable>(
        _ transform: @Sendable @escaping (Model) -> Output
    ) -> MappedGet<Model, Output> {
        MappedGet(getItemInput: self, transform: transform)
    }
}

// MARK: - TransactGetInput

/// A read transaction — an atomic, serializable snapshot of up to 100 items,
/// each addressed by primary key, that may span tables and models.
///
/// Where `batchGet` reads a single table, may be eventually consistent, and
/// returns the items it found in no guaranteed order, a `TransactGetInput`
/// reads every leg inside one DynamoDB `TransactGetItems` call: the reads see a
/// single consistent point in time, and the result is a *typed tuple* in the
/// same order the legs were declared — `nil` for any leg whose item was not
/// found.
///
///     let (hiker, hike) = try await TransactGet {
///         try Hiker.get(partitionKey: "hiker-1")                 // -> Hiker?
///         try Hike.get(partitionKey: "h", sortKey: "s")
///             .map { $0.toDomain() }                             // -> DomainHike?
///     }
///     .execute(using: client)
///
/// Legs are `ReadLeg`s: a raw `GetItemInput` (delivered as its model) or a
/// `.map`-ped leg (delivered as the mapped output) compose identically. Each
/// leg's `.project(_:)` works; `.consistentRead()` is accepted but ignored
/// (`TransactGetItems` is always serializable).
///
/// DynamoDB requires between 1 and 100 legs. A canceled read transaction
/// surfaces as `TransactionCanceled`.
public struct TransactGetInput<each Leg: ReadLeg>: Sendable {
    public let legs: (repeat each Leg)

    /// Build from an explicit, comma-separated list of legs.
    public init(_ legs: repeat each Leg) {
        self.legs = (repeat each legs)
    }

    /// Build the legs with the `TransactGet { ... }` closure DSL.
    public init(
        @TransactGetBuilder _ build: () throws -> (repeat each Leg)
    ) rethrows {
        self.legs = try build()
    }
}

// MARK: - Execute

extension TransactGetInput {
    /// Run the read transaction. Returns one optional per leg, in declaration
    /// order — each leg's `Output` type, with `nil` for a key that matched no
    /// item. The transport decodes to each leg's `Storage`; the leg's transform
    /// is applied afterward.
    public func execute(
        using client: any DynamoClient
    ) async throws -> (repeat (each Leg).Output?) {
        let storage = try await client.transactGet(repeat (each legs).getItemInput)
        return (repeat Self.apply(each storage, each legs))
    }

    /// Apply one leg's transform to its decoded storage item (if present).
    private static func apply<L: ReadLeg>(
        _ storage: L.Storage?,
        _ leg: L
    ) -> L.Output? {
        storage.map(leg.transform)
    }
}

// MARK: - Result builder

/// Result builder backing `TransactGetInput`. Only `buildBlock` is provided:
/// the result is a fixed-arity, statically-typed tuple, so control flow that
/// would change the number or types of legs (`if`, `for`, `switch`) can't be
/// expressed — and shouldn't be, since the caller binds the result positionally.
@resultBuilder
public enum TransactGetBuilder {
    public static func buildExpression<Leg: ReadLeg>(_ leg: Leg) -> Leg { leg }

    public static func buildBlock<each Leg: ReadLeg>(
        _ legs: repeat each Leg
    ) -> (repeat each Leg) {
        (repeat each legs)
    }
}

/// Spelling that mirrors the `TransactWriteInput { ... }` write side at the
/// call site: `TransactGet { ... }`.
public typealias TransactGet<each Leg: ReadLeg> = TransactGetInput<repeat each Leg>
