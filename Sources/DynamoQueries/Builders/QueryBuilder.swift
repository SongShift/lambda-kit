public struct QueryParts: Sendable {
    public let keyConditions: [Expression]
    public let filterConditions: [Expression]
}

public struct Key: Sendable {
    public let expressions: [Expression]

    public init(@KeyConditionBuilder _ build: () -> [Expression]) {
        self.expressions = build()
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
        QueryParts(keyConditions: key.expressions, filterConditions: [])
    }

    public static func buildBlock(_ key: Key, _ filter: Filter) -> QueryParts {
        QueryParts(keyConditions: key.expressions, filterConditions: filter.expressions)
    }
}
