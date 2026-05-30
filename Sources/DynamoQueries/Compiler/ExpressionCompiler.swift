/// Compiles `Expression` trees into DynamoDB expression strings, allocating
/// placeholders against a shared `PlaceholderAllocator`.
///
/// Stateless on purpose: every call writes its placeholders into the caller's
/// allocator, so a single request that mixes a key condition, a filter, and a
/// write condition can run all three through this compiler without their
/// placeholder spaces colliding.
public enum ExpressionCompiler {
    /// Compile an array of expressions joined by `AND` and return the
    /// resulting expression string. Returns `""` for an empty input. Callers
    /// that treat empty as "no expression" should check before assigning.
    public static func compile(
        _ expressions: [Expression],
        allocator: inout PlaceholderAllocator
    ) -> String {
        guard !expressions.isEmpty else { return "" }
        let combined = expressions.dropFirst().reduce(expressions[0]) {
            Expression.and($0, $1)
        }
        return compileNode(combined, allocator: &allocator)
    }

    private static func compileNode(
        _ expression: Expression,
        allocator: inout PlaceholderAllocator
    ) -> String {
        switch expression {
        case .equals(let attribute, let value):
            return compileBinary(operator: "=", attribute: attribute, value: value, allocator: &allocator)

        case .notEquals(let attribute, let value):
            return compileBinary(operator: "<>", attribute: attribute, value: value, allocator: &allocator)

        case .lessThan(let attribute, let value):
            return compileBinary(operator: "<", attribute: attribute, value: value, allocator: &allocator)

        case .lessThanOrEqual(let attribute, let value):
            return compileBinary(operator: "<=", attribute: attribute, value: value, allocator: &allocator)

        case .greaterThan(let attribute, let value):
            return compileBinary(operator: ">", attribute: attribute, value: value, allocator: &allocator)

        case .greaterThanOrEqual(let attribute, let value):
            return compileBinary(operator: ">=", attribute: attribute, value: value, allocator: &allocator)

        case .between(let attribute, let lower, let upper):
            let name = allocator.name(for: attribute)
            let lowerPlaceholder = allocator.value(for: lower)
            let upperPlaceholder = allocator.value(for: upper)
            return "\(name) BETWEEN \(lowerPlaceholder) AND \(upperPlaceholder)"

        case .beginsWith(let attribute, let value):
            let name = allocator.name(for: attribute)
            let valuePlaceholder = allocator.value(for: value)
            return "begins_with(\(name), \(valuePlaceholder))"

        case .contains(let attribute, let operand):
            let name = allocator.name(for: attribute)
            let valuePlaceholder = allocator.value(for: operand)
            return "contains(\(name), \(valuePlaceholder))"

        case .attributeExists(let attribute):
            return "attribute_exists(\(allocator.name(for: attribute)))"

        case .attributeNotExists(let attribute):
            return "attribute_not_exists(\(allocator.name(for: attribute)))"

        case .attributeType(let attribute, let type):
            let name = allocator.name(for: attribute)
            let valuePlaceholder = allocator.value(for: .string(type.rawValue))
            return "attribute_type(\(name), \(valuePlaceholder))"

        case .sizeComparison(let attribute, let op, let value):
            let name = allocator.name(for: attribute)
            let valuePlaceholder = allocator.value(for: value)
            return "size(\(name)) \(op.rawValue) \(valuePlaceholder)"

        case .sizeBetween(let attribute, let lower, let upper):
            let name = allocator.name(for: attribute)
            let lowerPlaceholder = allocator.value(for: lower)
            let upperPlaceholder = allocator.value(for: upper)
            return "size(\(name)) BETWEEN \(lowerPlaceholder) AND \(upperPlaceholder)"

        case .and(let lhs, let rhs):
            let leftExpression = compileNode(lhs, allocator: &allocator)
            let rightExpression = compileNode(rhs, allocator: &allocator)
            return "(\(leftExpression)) AND (\(rightExpression))"

        case .or(let lhs, let rhs):
            let leftExpression = compileNode(lhs, allocator: &allocator)
            let rightExpression = compileNode(rhs, allocator: &allocator)
            return "(\(leftExpression)) OR (\(rightExpression))"

        case .not(let inner):
            let innerExpression = compileNode(inner, allocator: &allocator)
            return "NOT (\(innerExpression))"
        }
    }

    private static func compileBinary(
        `operator`: String,
        attribute: String,
        value: DynamoValue,
        allocator: inout PlaceholderAllocator
    ) -> String {
        let name = allocator.name(for: attribute)
        let valuePlaceholder = allocator.value(for: value)
        return "\(name) \(`operator`) \(valuePlaceholder)"
    }
}
