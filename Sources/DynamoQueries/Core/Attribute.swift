import Foundation

/// Type-erased reference to an attribute by name. Lets variadic APIs
/// (`.attributes(MyModel.$a, MyModel.$b)`) accept `Attribute` values whose
/// phantom `Value` types differ.
public protocol AttributeReference: Sendable {
    var name: String { get }
}

/// A typed reference to a DynamoDB attribute name.
/// `Value` is a phantom type — it constrains operators, not storage.
public struct Attribute<Value>: Sendable, AttributeReference {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

// MARK: - size(path)

/// Marker protocol for attribute value types that DynamoDB's `size(path)`
/// function accepts: strings, binary, lists, maps, and sets.
///
/// `Optional` propagates the conformance via the conditional conformance
/// below — `Attribute<String?>.size` works because `String?` is `DynamoSizable`
/// when `String` is.
public protocol DynamoSizable {}

extension String: DynamoSizable {}
extension Data: DynamoSizable {}
extension Array: DynamoSizable {}
extension Set: DynamoSizable {}
extension Dictionary: DynamoSizable where Key == String {}
extension Optional: DynamoSizable where Wrapped: DynamoSizable {}

/// Builder returned by `Attribute.size`. Comparison operators and `between`
/// on this type compile to `size(name) OP :value` expressions.
public struct SizeExpression: Sendable {
    public let attributeName: String
}

extension Attribute where Value: DynamoSizable {
    /// Compile a `size(path)` reference. Compose with comparison operators
    /// or `between` to produce a filter / condition expression:
    ///
    ///     Filter { Self.$tags.size > 3 }
    public var size: SizeExpression {
        SizeExpression(attributeName: name)
    }
}

extension SizeExpression {
    public func between(_ lower: Int, and upper: Int) -> Expression {
        .sizeBetween(
            attributeName: attributeName,
            lower: lower.toDynamoValue(),
            upper: upper.toDynamoValue()
        )
    }
}

public func == (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .equals, value: rhs.toDynamoValue())
}

public func != (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .notEquals, value: rhs.toDynamoValue())
}

public func < (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .lessThan, value: rhs.toDynamoValue())
}

public func <= (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .lessThanOrEqual, value: rhs.toDynamoValue())
}

public func > (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .greaterThan, value: rhs.toDynamoValue())
}

public func >= (lhs: SizeExpression, rhs: Int) -> Expression {
    .sizeComparison(attributeName: lhs.attributeName, op: .greaterThanOrEqual, value: rhs.toDynamoValue())
}

// MARK: - Equality

public func == <Value: DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .equals(attributeName: lhs.name, value: rhs.toDynamoValue())
}

/// Allows querying optional-typed attributes with a non-nil value.
public func == <Value: DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .equals(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func != <Value: DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .notEquals(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func != <Value: DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .notEquals(attributeName: lhs.name, value: rhs.toDynamoValue())
}

// MARK: - Range operators

public func < <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .lessThan(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func < <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .lessThan(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func <= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .lessThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func <= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .lessThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func > <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .greaterThan(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func > <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .greaterThan(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func >= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> Expression {
    .greaterThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue())
}

public func >= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> Expression {
    .greaterThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue())
}

// MARK: - Between

extension Attribute where Value: Comparable & DynamoEncodable {
    public func between(_ lower: Value, and upper: Value) -> Expression {
        .between(
            attributeName: name,
            lower: lower.toDynamoValue(),
            upper: upper.toDynamoValue()
        )
    }
}

extension Attribute {
    /// Overload for optional-typed attributes (e.g. `Attribute<Date?>`), so callers can
    /// supply non-optional bounds without unwrapping the attribute's value type.
    public func between<Wrapped: Comparable & DynamoEncodable>(
        _ lower: Wrapped,
        and upper: Wrapped
    ) -> Expression where Value == Wrapped? {
        .between(
            attributeName: name,
            lower: lower.toDynamoValue(),
            upper: upper.toDynamoValue()
        )
    }
}

// MARK: - Existence

extension Attribute {
    /// `attribute_exists(name)` — true when the item has this attribute.
    public var exists: Expression {
        .attributeExists(attributeName: name)
    }

    /// `attribute_not_exists(name)` — true when the item lacks this attribute.
    /// The canonical "insert only if not present" guard is
    /// `Model.$partitionKey.doesNotExist`.
    public var doesNotExist: Expression {
        .attributeNotExists(attributeName: name)
    }

    /// `attribute_type(name, T)` — true when this attribute is currently of
    /// the given DynamoDB wire type. Useful for polymorphic attributes; rare
    /// in well-typed schemas.
    public func hasType(_ type: DynamoAttributeType) -> Expression {
        .attributeType(attributeName: name, type: type)
    }
}

// MARK: - String-specific operations

extension Attribute where Value == String {
    public func beginsWith(_ prefix: String) -> Expression {
        .beginsWith(attributeName: name, value: prefix.toDynamoValue())
    }

    /// `contains(name, :substring)` — true when the string value contains
    /// the given substring. DynamoDB's `contains` also operates on sets and
    /// lists; those overloads will land alongside set/list support in
    /// `DynamoValue`.
    public func contains(_ substring: String) -> Expression {
        .contains(attributeName: name, operand: substring.toDynamoValue())
    }
}

extension Attribute where Value == String? {
    public func beginsWith(_ prefix: String) -> Expression {
        .beginsWith(attributeName: name, value: prefix.toDynamoValue())
    }

    public func contains(_ substring: String) -> Expression {
        .contains(attributeName: name, operand: substring.toDynamoValue())
    }
}

// MARK: - Set / List membership

extension Attribute {
    /// `contains(set, :element)` — true when the set value contains the given
    /// element. The element type is enforced to match the set's element type
    /// via `DynamoSetElement`.
    public func contains<Element: DynamoSetElement>(_ element: Element) -> Expression
        where Value == Set<Element>
    {
        .contains(attributeName: name, operand: element.toDynamoValue())
    }

    public func contains<Element: DynamoSetElement>(_ element: Element) -> Expression
        where Value == Set<Element>?
    {
        .contains(attributeName: name, operand: element.toDynamoValue())
    }

    /// `contains(list, :element)` — true when the list value contains the
    /// given element.
    public func contains<Element: DynamoEncodable>(_ element: Element) -> Expression
        where Value == [Element]
    {
        .contains(attributeName: name, operand: element.toDynamoValue())
    }

    public func contains<Element: DynamoEncodable>(_ element: Element) -> Expression
        where Value == [Element]?
    {
        .contains(attributeName: name, operand: element.toDynamoValue())
    }
}

// MARK: - Update DSL

extension Attribute where Value: DynamoEncodable {
    /// SET this attribute to the given value.
    public func set(to value: Value) -> UpdateAction {
        .set(attributeName: name, value: value.toDynamoValue())
    }

    /// SET this attribute only if it doesn't currently exist on the item —
    /// compiles to `SET attr = if_not_exists(attr, :fallback)`. Useful for
    /// `createdAt`-style fields that should be initialized on first write
    /// and left alone on subsequent updates.
    public func setIfNotExists(_ fallback: Value) -> UpdateAction {
        .setIfNotExists(attributeName: name, fallback: fallback.toDynamoValue())
    }
}

extension Attribute {
    /// SET an optional-typed attribute, accepting the non-optional wrapped value.
    public func set<Wrapped: DynamoEncodable>(to value: Wrapped) -> UpdateAction
        where Value == Wrapped? {
        .set(attributeName: name, value: value.toDynamoValue())
    }

    public func setIfNotExists<Wrapped: DynamoEncodable>(_ fallback: Wrapped) -> UpdateAction
        where Value == Wrapped? {
        .setIfNotExists(attributeName: name, fallback: fallback.toDynamoValue())
    }

    /// REMOVE this attribute from the item. Available for any attribute —
    /// removing a value DynamoDB doesn't have is a no-op.
    public func remove() -> UpdateAction {
        .remove(attributeName: name)
    }
}

extension Attribute where Value: Numeric & DynamoEncodable {
    /// ADD `delta` to this numeric attribute atomically. Unlike
    /// `set(to: attr + delta)`-style expressions, ADD works whether the
    /// attribute currently exists or not — the canonical pattern for
    /// incrementing counters.
    public func add(_ delta: Value) -> UpdateAction {
        .add(attributeName: name, value: delta.toDynamoValue())
    }
}

extension Attribute {
    public func add<Wrapped: Numeric & DynamoEncodable>(_ delta: Wrapped) -> UpdateAction
        where Value == Wrapped? {
        .add(attributeName: name, value: delta.toDynamoValue())
    }
}

// MARK: - List append / prepend

extension Attribute {
    /// Append `items` to a list attribute. Compiles to
    /// `SET name = list_append(if_not_exists(name, :empty), :items)` so the
    /// expression succeeds whether the attribute already exists or not —
    /// missing becomes an empty list, then the new items are appended.
    public func append<Element: DynamoEncodable>(_ items: [Element]) -> UpdateAction
        where Value == [Element] {
        .listAppend(attributeName: name, items: items.toDynamoValue())
    }

    public func append<Element: DynamoEncodable>(_ items: [Element]) -> UpdateAction
        where Value == [Element]? {
        .listAppend(attributeName: name, items: items.toDynamoValue())
    }

    /// Prepend `items` to a list attribute. Compiles to
    /// `SET name = list_append(:items, if_not_exists(name, :empty))` so the
    /// expression succeeds whether the attribute already exists or not.
    public func prepend<Element: DynamoEncodable>(_ items: [Element]) -> UpdateAction
        where Value == [Element] {
        .listPrepend(attributeName: name, items: items.toDynamoValue())
    }

    public func prepend<Element: DynamoEncodable>(_ items: [Element]) -> UpdateAction
        where Value == [Element]? {
        .listPrepend(attributeName: name, items: items.toDynamoValue())
    }
}

// MARK: - Set element add / remove

extension Attribute {
    /// Add the given elements to a set attribute (DynamoDB `ADD` clause for
    /// sets — distinct from ADD on a numeric attribute, which increments).
    /// Set semantics: duplicates are silently no-ops.
    public func addToSet<Element: DynamoSetElement>(_ elements: Set<Element>) -> UpdateAction
        where Value == Set<Element> {
        .add(attributeName: name, value: elements.toDynamoValue())
    }

    public func addToSet<Element: DynamoSetElement>(_ elements: Set<Element>) -> UpdateAction
        where Value == Set<Element>? {
        .add(attributeName: name, value: elements.toDynamoValue())
    }

    /// Remove the given elements from a set attribute (DynamoDB `DELETE`
    /// clause for sets — distinct from `remove()` which deletes the whole
    /// attribute).
    public func removeFromSet<Element: DynamoSetElement>(_ elements: Set<Element>) -> UpdateAction
        where Value == Set<Element> {
        .delete(attributeName: name, value: elements.toDynamoValue())
    }

    public func removeFromSet<Element: DynamoSetElement>(_ elements: Set<Element>) -> UpdateAction
        where Value == Set<Element>? {
        .delete(attributeName: name, value: elements.toDynamoValue())
    }
}
