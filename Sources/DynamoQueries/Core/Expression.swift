public indirect enum Expression: Sendable, Equatable {
    case equals(attributeName: String, value: DynamoValue)
    case notEquals(attributeName: String, value: DynamoValue)
    case lessThan(attributeName: String, value: DynamoValue)
    case lessThanOrEqual(attributeName: String, value: DynamoValue)
    case greaterThan(attributeName: String, value: DynamoValue)
    case greaterThanOrEqual(attributeName: String, value: DynamoValue)
    case between(attributeName: String, lower: DynamoValue, upper: DynamoValue)
    case beginsWith(attributeName: String, value: DynamoValue)
    case contains(attributeName: String, operand: DynamoValue)
    case attributeExists(attributeName: String)
    case attributeNotExists(attributeName: String)
    case attributeType(attributeName: String, type: DynamoAttributeType)
    case sizeComparison(attributeName: String, op: SizeComparisonOp, value: DynamoValue)
    case sizeBetween(attributeName: String, lower: DynamoValue, upper: DynamoValue)
    case and(Expression, Expression)
    case or(Expression, Expression)
    case not(Expression)
}

/// The set of comparison operators DynamoDB allows on the `size(path)`
/// function's result.
public enum SizeComparisonOp: String, Sendable, Equatable {
    case equals = "="
    case notEquals = "<>"
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
}

// MARK: - Logical operators

/// Compose two expressions with `AND`. Equivalent to writing them on
/// successive lines inside a `Filter` / `Condition` block, but useful when
/// building a single compound expression, typically inside an `||` group.
public func && (lhs: Expression, rhs: Expression) -> Expression {
    .and(lhs, rhs)
}

/// Compose two expressions with `OR`. Filter and condition blocks AND their
/// lines together by default; reach for `||` when one of those lines needs
/// to be a disjunction.
public func || (lhs: Expression, rhs: Expression) -> Expression {
    .or(lhs, rhs)
}

/// Negate an expression. The compiler always parenthesizes the inner
/// expression, so `!(a && b)` and `!a && !b` produce different (and
/// correct) DynamoDB expressions.
public prefix func ! (expression: Expression) -> Expression {
    .not(expression)
}
