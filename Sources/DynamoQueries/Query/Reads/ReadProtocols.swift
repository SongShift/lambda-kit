/// Read abstractions that let a call site name *what a read delivers* without
/// naming *how it's stored*. Each has a primary associated type `Output`, so a
/// repository can return `some PagedRead<DomainHike>` and keep the on-table
/// storage model out of its signature entirely.
///
/// There are three, one per terminal shape — they can't be collapsed into one,
/// because the shapes genuinely differ:
///
/// | protocol      | conformers                          | terminal(s) |
/// |---------------|-------------------------------------|-------------|
/// | `Read`     | `GetItemInput`, `MappedGet`         | `execute → Output?`, composes in `TransactGet` |
/// | `BatchRead`   | `BatchGetInput`, `MappedBatchGet`   | `execute → [Output]` |
/// | `PagedRead`   | `QueryInput`/`ScanInput`, `Mapped*` | `execute → QueryPage<Output>`, `pages`, `executeAll → [Output]`, `count` |
///
/// (`Read` lives in `TransactGet.swift`, alongside the transaction it feeds.)
///
/// The raw inputs conform too, with `Output == Model` — so `some PagedRead<Hike>`
/// names an un-mapped query just as well as a mapped one.

// MARK: - BatchRead

/// A multi-key read delivering `[Output]`. Conformed by `BatchGetInput` (raw,
/// `Output == Model`) and `MappedBatchGet`.
public protocol BatchRead<Output>: Sendable {
    associatedtype Output: Sendable
    func execute(using client: any DynamoClient) async throws -> [Output]
}

extension BatchGetInput: BatchRead {}
extension MappedBatchGet: BatchRead {}

// MARK: - PagedRead

/// A paginated read delivering pages of `Output`. Conformed by `QueryInput` and
/// `ScanInput` (raw, `Output == Model`) and by `MappedQuery` / `MappedScan`.
/// Exposes the full paged surface so an opaque `some PagedRead<Output>` loses
/// no capability: single page, lazy page stream, auto-paginated array, or count.
public protocol PagedRead<Output>: Sendable {
    associatedtype Output: Sendable
    associatedtype Pages: AsyncSequence where Pages.Element == QueryPage<Output>

    /// One page of results.
    func execute(using client: any DynamoClient) async throws -> QueryPage<Output>
    /// Lazily stream pages; each `next()` fires one request.
    func pages(using client: any DynamoClient) -> Pages
    /// Auto-paginate into a flat array.
    func executeAll(using client: any DynamoClient) async throws -> [Output]
    /// Count matching items via `Select: COUNT`, ignoring any transform.
    func count(using client: any DynamoClient) async throws -> Int
}

extension QueryInput: PagedRead {}
extension ScanInput: PagedRead {}
extension MappedQuery: PagedRead {}
extension MappedScan: PagedRead {}
