import Foundation

/// An opaque cursor pointing to the next page of a paginated query.
///
/// Internally wraps DynamoDB's `LastEvaluatedKey` (the primary key of the last
/// item returned). Callers should treat the string form as opaque — it is base64
/// JSON, but that representation is not part of the public contract and may
/// change.
///
/// `PaginationToken` is `Codable` as a single string, so it can be embedded
/// directly in JSON API responses without producing a nested object.
public struct PaginationToken: Sendable, Equatable {
    public let key: [String: DynamoValue]

    /// Construct a token from a raw primary-key map. Intended for transport
    /// adapters (e.g. the Soto bridge); application code should round-trip
    /// tokens through `init(string:)` / `stringValue` instead.
    public init(key: [String: DynamoValue]) {
        self.key = key
    }

    /// Reconstruct a token from its opaque string form. Returns `nil` if the
    /// string is not a valid token (e.g. tampered with or from a different
    /// schema version).
    public init?(string: String) {
        guard let data = Data(base64Encoded: string),
              let key = try? JSONDecoder().decode([String: DynamoValue].self, from: data)
        else { return nil }
        self.key = key
    }

    /// Opaque string form, suitable for round-tripping through API responses.
    public var stringValue: String {
        let data = (try? JSONEncoder().encode(self.key)) ?? Data()
        return data.base64EncodedString()
    }
}

extension PaginationToken: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let token = PaginationToken(string: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid PaginationToken"
            )
        }
        self = token
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.stringValue)
    }
}

// MARK: - QueryPage

/// A single page of query results, plus a cursor for the next page if more
/// results are available.
///
/// `nextToken` is `nil` when the query has been fully consumed. Callers should
/// loop until they get a `nil` token, not until `items` is empty — DynamoDB can
/// return an empty page with a non-nil token (e.g. when a filter eliminates
/// every item in the scanned window).
public struct QueryPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextToken: PaginationToken?

    public init(items: [Item], nextToken: PaginationToken?) {
        self.items = items
        self.nextToken = nextToken
    }

    public func map<Output: Sendable>(
        _ transform: (Item) -> Output
    ) -> QueryPage<Output> {
        QueryPage<Output>(items: items.map(transform), nextToken: nextToken)
    }
}

// MARK: - CountPage

/// A single page of a count-only Query/Scan response. `count` is the number
/// of matching items in this page (after filter), `scannedCount` is what
/// DynamoDB read before applying the filter — useful for spotting hot spots
/// where a filter is doing too much work.
public struct CountPage: Sendable {
    public let count: Int
    public let scannedCount: Int
    public let nextToken: PaginationToken?

    public init(count: Int, scannedCount: Int, nextToken: PaginationToken?) {
        self.count = count
        self.scannedCount = scannedCount
        self.nextToken = nextToken
    }
}
