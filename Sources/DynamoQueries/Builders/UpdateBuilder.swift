@resultBuilder
public struct UpdateBuilder {
    public static func buildExpression(_ expression: UpdateAction) -> [UpdateAction] {
        [expression]
    }

    public static func buildBlock(_ components: [UpdateAction]...) -> [UpdateAction] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [UpdateAction]?) -> [UpdateAction] {
        component ?? []
    }

    public static func buildEither(first component: [UpdateAction]) -> [UpdateAction] {
        component
    }

    public static func buildEither(second component: [UpdateAction]) -> [UpdateAction] {
        component
    }

    public static func buildArray(_ components: [[UpdateAction]]) -> [UpdateAction] {
        components.flatMap { $0 }
    }
}
