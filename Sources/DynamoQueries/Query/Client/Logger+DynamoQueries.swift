import Logging

public extension Logger {
    /// The logger DynamoQueries `execute` calls use when the caller doesn't
    /// supply one. Routes to a no-op handler, so reads and writes stay silent
    /// unless a call site opts in by passing its own `logger:`.
    static let dynamoQueriesDisabled = Logger(
        label: "DynamoQueries",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
}
