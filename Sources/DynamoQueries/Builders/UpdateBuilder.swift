@resultBuilder
public struct UpdateBuilder {
    public static func buildBlock(_ components: UpdateAction...) -> [UpdateAction] {
        Array(components)
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
