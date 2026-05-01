/// Thrown by `Put` / `Update` / `Delete` execute calls when the request's
/// condition expression evaluates to false on the server.
///
/// Adapters MUST translate the underlying transport-level conditional-check
/// failure into this typed error so call sites can `catch let conflict as
/// ConditionalCheckFailed<Model>` without dropping into vendor-specific error
/// types.
///
/// `priorItem` is the item that was actually present when the condition was
/// evaluated — i.e., the item that caused the conflict. It's only populated
/// when the request was built with `.returnConflictingItem()`; otherwise it
/// is `nil`. (The flag costs an extra DynamoDB read on the failure path, so
/// it's opt-in.) `priorItem` will also be `nil` if the prior item exists but
/// fails to decode as `Model` — e.g., the schema has drifted since the row
/// was written.
public struct ConditionalCheckFailed<Model: DynamoModel>: Error, Sendable {
    public let tableName: String
    public let priorItem: Model?

    public init(tableName: String, priorItem: Model?) {
        self.tableName = tableName
        self.priorItem = priorItem
    }
}
