import DynamoQueries
import SotoDynamoDB

/// The default `DynamoExpressionRepresentation` for `Codable` aggregates:
/// encodes any `Encodable` value through the same Soto-backed encoder
/// `SotoDynamoClient` uses for full items — including the `.secondsSince1970`
/// date strategy — so a targeted `set` writes exactly what a `put` of the
/// whole model would store for that property.
/// 
/// Reach for this whenever the property's own `Codable` conformance defines
/// its wire format — the common case for nested structs. Hand-roll a
/// `DynamoExpressionRepresentation` only when the stored format deviates from
/// what `Codable` plus the adapter's pinned strategies produce.
///
/// The value must encode as a keyed container (a DynamoDB map). Scalar types
/// conform to `DynamoEncodable` already and don't need a representation.
public enum SotoCodableEncoder<Value: Encodable>: DynamoExpressionRepresentation {
    public static func encode(_ value: Value) throws -> DynamoValue {
        try .map(DynamoEncoder.encode(value).mapValues { $0.toDynamoValue() })
    }
}
