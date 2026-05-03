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
}

@resultBuilder
public enum QueryBuilder {
    public static func buildBlock(_ key: Key) -> QueryParts {
        QueryParts(keyConditions: key.conditions, filterConditions: [])
    }

    public static func buildBlock(_ key: Key, _ filter: Filter) -> QueryParts {
        QueryParts(keyConditions: key.conditions, filterConditions: filter.expressions)
    }
}
