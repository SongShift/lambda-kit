/// A result builder for conditional-write `where:` blocks on `put`,
/// `update`, and `delete`. Structurally identical to `FilterBuilder`,
/// separate so call sites read naturally (a closure labeled `where:`
/// belongs to a `ConditionBuilder`, not a `FilterBuilder`).
@resultBuilder
public struct ConditionBuilder {
    public static func buildExpression(_ expression: Expression) -> Expression {
        expression
    }

    public static func buildBlock(_ components: Expression...) -> [Expression] {
        Array(components)
    }

    public static func buildOptional(_ component: [Expression]?) -> [Expression] {
        component ?? []
    }

    public static func buildEither(first component: [Expression]) -> [Expression] {
        component
    }

    public static func buildEither(second component: [Expression]) -> [Expression] {
        component
    }

    public static func buildArray(_ components: [[Expression]]) -> [Expression] {
        components.flatMap { $0 }
    }
}
