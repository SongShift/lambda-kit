/// Thrown by `UpdateReturning.execute(using:)` when the update succeeded but
/// DynamoDB's response carried no attributes to decode.
///
/// `allNew` always reports attributes after a successful update, so this
/// mostly surfaces on the `allOld` / `updatedOld` modes when the update
/// created the item (there were no prior values to return), and on
/// `updatedNew` when the update touched nothing DynamoDB reports back.
///
/// Adapters MUST throw this rather than inventing an empty `Model`. Attributes
/// that *are* present but fail to decode propagate as the decoder's own error
/// instead — a missing response and a schema mismatch are different bugs.
public struct ReturnedAttributesNotFound<Model: DynamoModel>: Error, Sendable {
    public let tableName: String

    public init(tableName: String) {
        self.tableName = tableName
    }
}

extension ReturnedAttributesNotFound: DynamoError {
    public var isRetryable: Bool { false }
}
