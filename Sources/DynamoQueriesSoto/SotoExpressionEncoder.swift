import DynamoQueries
import SotoDynamoDB

/// The canonical ``DynamoExpressionRepresentation``: encodes any `Codable`
/// value into its native DynamoDB form (nested structs as `M` maps, arrays
/// as `L` lists, `[Int: V]` as an `M` map with stringified keys via
/// `CodingKeyRepresentable`).
///
/// Encodes through the same Soto `DynamoDBEncoder` configuration the put
/// path uses (`DynamoEncoder` / `DynamoDecoder`), so a column declared
///
///     @ExpressionValue(as: SotoExpressionEncoder<[Int: GearSlot]>.self)
///     var slots: [Int: GearSlot]
///
/// produces byte-identical storage whether the value arrives via a full-item
/// put (the model's `Codable` conformance) or a targeted
/// `try $0.slots.set(to:)`. The same `AWSBase64Data` and `Date` conventions
/// apply — see the Codable-bridge notes in `SotoClient.swift`.
public enum SotoExpressionEncoder<Value: Codable & Sendable>: DynamoExpressionRepresentation {
    /// Wrapping the value lets non-keyed top-levels (arrays, scalars) ride
    /// through Soto's encoder, which only encodes keyed containers at the
    /// top level.
    private struct Box: Codable {
        let value: Value
    }

    public static func encode(_ value: Value) throws -> DynamoValue {
        let item = try DynamoEncoder.encode(Box(value: value))
        // A missing key means the value encoded as nothing (e.g. `nil` via
        // `encodeIfPresent` semantics); surface that as an explicit NULL.
        return item["value"]?.toDynamoValue() ?? .null
    }

    /// Not part of ``DynamoExpressionRepresentation`` (the DSL only encodes)
    /// and not public API; package-scoped so tests can verify a value
    /// round-trips through the same coder configuration the read path uses.
    package static func decode(_ value: DynamoValue) throws -> Value {
        try DynamoDecoder.decode(Box.self, from: ["value": value.toSotoAttributeValue()]).value
    }
}
