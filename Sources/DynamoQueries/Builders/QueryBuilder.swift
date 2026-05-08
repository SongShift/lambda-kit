public struct QueryParts: Sendable {
    public let keyConditions: [KeyCondition]
    public let filterConditions: [Expression]
}

public struct Key: Sendable {
    public let conditions: [KeyCondition]

    public init(@KeyConditionBuilder _ build: () -> [KeyCondition]) {
        self.conditions = build()
    }
}

public struct Filter: Sendable {
    public let expressions: [Expression]

    public init(@FilterBuilder _ build: () -> [Expression]) {
        self.expressions = build()
    }

    init(expressions: [Expression]) {
        self.expressions = expressions
    }
}

/// Builds a `QueryParts` from one mandatory `Key { ... }` followed by zero
/// or more `Filter { ... }` blocks. Top-level `if` / `if let` / `if/else` /
/// `for` are supported around `Filter` blocks; the `Key` itself must always
/// be present and unambiguous, since DynamoDB queries require exactly one
/// set of key conditions.
@resultBuilder
public enum QueryBuilder {
    public static func buildPartialBlock(first key: Key) -> QueryParts {
        QueryParts(keyConditions: key.conditions, filterConditions: [])
    }

    public static func buildPartialBlock(accumulated: QueryParts, next: Filter) -> QueryParts {
        QueryParts(
            keyConditions: accumulated.keyConditions,
            filterConditions: accumulated.filterConditions + next.expressions
        )
    }

    public static func buildPartialBlock(first filter: Filter) -> Filter {
        filter
    }

    public static func buildPartialBlock(accumulated: Filter, next: Filter) -> Filter {
        Filter(expressions: accumulated.expressions + next.expressions)
    }

    public static func buildOptional(_ component: Filter?) -> Filter {
        component ?? Filter(expressions: [])
    }

    public static func buildEither(first component: Filter) -> Filter {
        component
    }

    public static func buildEither(second component: Filter) -> Filter {
        component
    }

    public static func buildArray(_ components: [Filter]) -> Filter {
        Filter(expressions: components.flatMap { $0.expressions })
    }
}
