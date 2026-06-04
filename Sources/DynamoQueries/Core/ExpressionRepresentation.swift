/// An encoding strategy for rendering a column's values into expression
/// attribute values, for Swift types that can't (or shouldn't) conform to
/// `DynamoEncodable` directly — nested `Codable` structs, non-string-keyed
/// dictionaries, JSON blobs.
///
/// The library ships only this seam — conformances are declared by the
/// consumer, next to the schema that owns the type:
///
///     enum GearSlotMapEncoder: DynamoExpressionRepresentation {
///         static func encode(_ value: [Int: GearSlot]) throws -> DynamoValue { ... }
///     }
///
///     @Table("Lockers")
///     struct Locker: Codable {
///         @PartitionKey var id: String
///         @ExpressionValue(as: GearSlotMapEncoder.self)
///         var slots: [Int: GearSlot]
///     }
///
/// `@Table` then generates the column as a ``RepresentedAttribute`` whose
/// update DSL routes values through the representation:
///
///     Locker.update(partitionKey: id) {
///         try $0.slots.set(to: slots)
///     }
///
/// Unlike `DynamoEncodable.toDynamoValue()`, conversion is throwing —
/// representations that bridge through `Codable` can fail.
///
/// Representations don't govern full-item puts or reads: those go through
/// the model's own `Codable` conformance. A representation must produce the
/// same wire format the model's `encode(to:)` does for that property, or
/// `set` and `put` will disagree about what's stored. Encoding is the only
/// requirement: representations feed values *into* expressions, and reads
/// never route through them, so there is nothing for the library to decode.
public protocol DynamoExpressionRepresentation: Sendable {
    associatedtype Value

    /// Convert a Swift value to its stored `DynamoValue` form.
    static func encode(_ value: Value) throws -> DynamoValue
}

/// A typed reference to a column declared with `@ExpressionValue(as:)`. Mirrors
/// ``Attribute``, but values pass through the column's
/// ``DynamoExpressionRepresentation`` instead of `DynamoEncodable`, so the
/// value-carrying operations are throwing.
///
/// Value *comparisons* (`==`, `contains`, …) are deliberately not offered:
/// filter and condition closures are non-throwing, and comparing against a
/// representation-encoded blob is rarely meaningful. Existence checks and
/// `remove()` don't touch values, so they match `Attribute`'s surface.
public struct RepresentedAttribute<Rep: DynamoExpressionRepresentation>: Sendable, AttributeReference {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    // MARK: Update DSL

    /// SET this attribute to the given value, encoded via `Rep`.
    public func set(to value: Rep.Value) throws -> UpdateAction {
        .set(attributeName: name, value: try Rep.encode(value))
    }

    /// SET this attribute only if it doesn't currently exist on the item.
    /// See `Attribute.setIfNotExists(_:)`.
    public func setIfNotExists(_ fallback: Rep.Value) throws -> UpdateAction {
        .setIfNotExists(attributeName: name, fallback: try Rep.encode(fallback))
    }

    /// REMOVE this attribute from the item.
    public func remove() -> UpdateAction {
        .remove(attributeName: name)
    }

    // MARK: Existence

    /// `attribute_exists(name)`: true when the item has this attribute.
    public var exists: Expression {
        .attributeExists(attributeName: name)
    }

    /// `attribute_not_exists(name)`: true when the item lacks this attribute.
    public var doesNotExist: Expression {
        .attributeNotExists(attributeName: name)
    }
}
