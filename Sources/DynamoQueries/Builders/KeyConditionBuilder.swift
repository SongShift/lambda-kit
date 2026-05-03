@resultBuilder
public struct KeyConditionBuilder {
    public static func buildExpression(_ condition: KeyCondition) -> KeyCondition {
        condition
    }

    public static func buildBlock(_ components: KeyCondition...) -> [KeyCondition] {
        Array(components)
    }

    public static func buildOptional(_ component: [KeyCondition]?) -> [KeyCondition] {
        component ?? []
    }

    public static func buildEither(first component: [KeyCondition]) -> [KeyCondition] {
        component
    }

    public static func buildEither(second component: [KeyCondition]) -> [KeyCondition] {
        component
    }
}
