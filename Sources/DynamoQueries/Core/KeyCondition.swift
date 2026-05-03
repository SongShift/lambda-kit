/// A single key-condition expression, distinct from the broader
/// ``Expression`` used by `Filter` / `where:` blocks. DynamoDB's
/// `KeyConditionExpression` only accepts a small subset of operators on
/// the table's partition and sort key — exposing those operators with a
/// dedicated return type keeps unsafe operators (`contains`, `!=`,
/// existence checks, `&&` / `||` / `!`) from compiling inside `Key { }`.
public struct KeyCondition: Sendable, Equatable {
    public let expression: Expression

    init(_ expression: Expression) {
        self.expression = expression
    }
}

// MARK: - Attribute → KeyCondition operators
//
// These overloads sit alongside the `Attribute` operators that return
// `Expression`. Result-builder context drives selection: `Key { ... }`
// resolves to the `KeyCondition` overload because `KeyConditionBuilder`
// only accepts `KeyCondition`; `Filter { ... }` resolves to the
// `Expression` overload because `FilterBuilder` only accepts `Expression`.
//
// Operators DynamoDB rejects in a key condition (`contains`, `!=`,
// existence, boolean composition) have no `KeyCondition` overload, so
// they fail to compile inside `Key`.

public func == <Value: DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> KeyCondition {
    KeyCondition(.equals(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

public func == <Value: DynamoEncodable>(lhs: Attribute<Value?>, rhs: Value) -> KeyCondition {
    KeyCondition(.equals(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

public func < <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> KeyCondition {
    KeyCondition(.lessThan(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

public func <= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> KeyCondition {
    KeyCondition(.lessThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

public func > <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> KeyCondition {
    KeyCondition(.greaterThan(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

public func >= <Value: Comparable & DynamoEncodable>(lhs: Attribute<Value>, rhs: Value) -> KeyCondition {
    KeyCondition(.greaterThanOrEqual(attributeName: lhs.name, value: rhs.toDynamoValue()))
}

extension Attribute where Value: Comparable & DynamoEncodable {
    public func between(_ lower: Value, and upper: Value) -> KeyCondition {
        KeyCondition(.between(
            attributeName: name,
            lower: lower.toDynamoValue(),
            upper: upper.toDynamoValue()
        ))
    }
}

extension Attribute where Value == String {
    public func beginsWith(_ prefix: String) -> KeyCondition {
        KeyCondition(.beginsWith(attributeName: name, value: prefix.toDynamoValue()))
    }
}
