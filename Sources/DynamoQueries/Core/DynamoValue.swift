import Foundation

/// A value matching one of DynamoDB's attribute-value variants.
///
/// Mirrors the wire-level surface (`S`, `N`, `BOOL`, `B`, `NULL`, `L`, `M`,
/// `SS`, `NS`, `BS`). Numbers are carried as their string serialization.
/// DynamoDB sends them that way to preserve arbitrary-precision values that
/// would round-trip lossily through `Double`.
public enum DynamoValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case bool(Bool)
    case binary(Data)
    case null
    case list([DynamoValue])
    case map([String: DynamoValue])
    case stringSet(Set<String>)
    /// DynamoDB number-set elements travel as their string serialization for
    /// the same reason single numbers do, preserving precision. The
    /// `Set<Int>` / `Set<Double>` `DynamoEncodable` conformances do the
    /// conversion for you.
    case numberSet(Set<String>)
    case binarySet(Set<Data>)
}

// MARK: - Codable

/// Encoded using DynamoDB's wire-format type discriminators. Pagination
/// tokens depend on this round-trip; new variants must be added to both
/// `init(from:)` and `encode(to:)` together.
extension DynamoValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case string = "S"
        case number = "N"
        case bool = "BOOL"
        case binary = "B"
        case null = "NULL"
        case list = "L"
        case map = "M"
        case stringSet = "SS"
        case numberSet = "NS"
        case binarySet = "BS"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .string) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .number) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .binary) {
            guard let data = Data(base64Encoded: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .binary,
                    in: container,
                    debugDescription: "B value is not valid base64"
                )
            }
            self = .binary(data)
        } else if let isNull = try container.decodeIfPresent(Bool.self, forKey: .null), isNull {
            self = .null
        } else if let value = try container.decodeIfPresent([DynamoValue].self, forKey: .list) {
            self = .list(value)
        } else if let value = try container.decodeIfPresent([String: DynamoValue].self, forKey: .map) {
            self = .map(value)
        } else if let value = try container.decodeIfPresent([String].self, forKey: .stringSet) {
            self = .stringSet(Set(value))
        } else if let value = try container.decodeIfPresent([String].self, forKey: .numberSet) {
            self = .numberSet(Set(value))
        } else if let value = try container.decodeIfPresent([String].self, forKey: .binarySet) {
            let datas = try value.map { encoded -> Data in
                guard let data = Data(base64Encoded: encoded) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .binarySet,
                        in: container,
                        debugDescription: "BS element is not valid base64"
                    )
                }
                return data
            }
            self = .binarySet(Set(datas))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "DynamoValue must encode exactly one of S, N, BOOL, B, NULL, L, M, SS, NS, BS"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .string)
        case .number(let value): try container.encode(value, forKey: .number)
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .binary(let value): try container.encode(value.base64EncodedString(), forKey: .binary)
        case .null: try container.encode(true, forKey: .null)
        case .list(let value): try container.encode(value, forKey: .list)
        case .map(let value): try container.encode(value, forKey: .map)
        // Sets serialize as sorted arrays to keep the JSON form stable
        // (helpful for byte-equal token round-trips).
        case .stringSet(let value): try container.encode(value.sorted(), forKey: .stringSet)
        case .numberSet(let value): try container.encode(value.sorted(), forKey: .numberSet)
        case .binarySet(let value):
            try container.encode(value.map { $0.base64EncodedString() }.sorted(), forKey: .binarySet)
        }
    }
}

// MARK: - DynamoEncodable

public protocol DynamoEncodable: Sendable {
    func toDynamoValue() -> DynamoValue
}

extension String: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .string(self) }
}

extension Int: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .number(String(self)) }
}

extension Double: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .number(String(self)) }
}

extension Bool: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .bool(self) }
}

extension URL: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .string(absoluteString) }
}

extension Data: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { .binary(self) }
}

/// `Date` encodes as epoch-seconds in a Number: keeps values sortable in
/// DynamoDB indexes (an ISO8601 string is also sortable, but epoch-seconds
/// is shorter on the wire and stays correct across timezones without further
/// thought). `Date` is `Comparable`, so `Attribute<Date>` automatically
/// picks up `==`, `!=`, `<`, `<=`, `>`, `>=`, and `.between(_:and:)` from
/// the existing comparison operators.
extension Date: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue {
        .number(String(timeIntervalSince1970))
    }
}

extension DynamoEncodable where Self: RawRepresentable, RawValue: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue { rawValue.toDynamoValue() }
}

// MARK: - Collections

extension Array: DynamoEncodable where Element: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue {
        .list(map { $0.toDynamoValue() })
    }
}

extension Dictionary: DynamoEncodable where Key == String, Value: DynamoEncodable {
    public func toDynamoValue() -> DynamoValue {
        .map(mapValues { $0.toDynamoValue() })
    }
}

// DynamoDB only models string, number, and binary sets. `DynamoSetElement`
// is the marker that gates which `Set<T>` types can be DynamoEncodable:
// `String`, `Int`, `Double`, and `Data`. `Set<Bool>` and other element types
// deliberately don't get a conformance.
public protocol DynamoSetElement: DynamoEncodable & Hashable {
    static func _toDynamoSet(_ elements: Set<Self>) -> DynamoValue
}

extension String: DynamoSetElement {
    public static func _toDynamoSet(_ elements: Set<String>) -> DynamoValue {
        .stringSet(elements)
    }
}

extension Int: DynamoSetElement {
    public static func _toDynamoSet(_ elements: Set<Int>) -> DynamoValue {
        .numberSet(Set(elements.map { String($0) }))
    }
}

extension Double: DynamoSetElement {
    public static func _toDynamoSet(_ elements: Set<Double>) -> DynamoValue {
        .numberSet(Set(elements.map { String($0) }))
    }
}

extension Data: DynamoSetElement {
    public static func _toDynamoSet(_ elements: Set<Data>) -> DynamoValue {
        .binarySet(elements)
    }
}

extension Set: DynamoEncodable where Element: DynamoSetElement {
    public func toDynamoValue() -> DynamoValue {
        Element._toDynamoSet(self)
    }
}
