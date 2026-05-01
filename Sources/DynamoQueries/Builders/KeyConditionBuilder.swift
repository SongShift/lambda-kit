@resultBuilder
public struct KeyConditionBuilder {
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
}
