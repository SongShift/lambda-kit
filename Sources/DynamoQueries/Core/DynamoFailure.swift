/// Adapter-agnostic description of why a DynamoDB operation failed.
///
/// `DynamoFailure` is the shared currency across every lambda-kit error type.
/// It pairs a categorized `Reason` (the *what kind of thing*) with an optional
/// message (the *human-readable detail*). Adapters map their native error
/// shapes into this struct; callers consume it without importing the adapter.
///
/// Typed errors that carry richer payload sit *above* this layer and
/// reference `DynamoFailure` rather than duplicating it:
///
/// - `ConditionalCheckFailed<Model>` is thrown for single-item conditional
///   failures and carries the decoded prior item.
/// - `TransactionCanceled` is thrown for transaction-level failures and
///   carries a per-leg `DynamoFailure?` (with `nil` meaning "this leg
///   succeeded — DynamoDB just reported it for completeness").
public struct DynamoFailure: Error, Sendable {
    public let reason: Reason
    /// Human-readable detail from the server, when available. Useful for
    /// debugging and for surfacing validation messages to logs; not intended
    /// for branching on (use `reason` for that).
    public let message: String?

    public init(reason: Reason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }

    /// Categorized failure mode. Closed set of cases lambda-kit understands,
    /// with `.unknown` as the escape hatch for new or unrecognized codes.
    public enum Reason: Sendable, Equatable {
        // MARK: Retryable

        /// Account- or service-level rate limiting.
        case throttled

        /// Table or index exceeded provisioned capacity.
        case throughputExceeded

        /// A different transaction is currently in flight against an item
        /// this request touches. Generally resolves on a short backoff.
        case transactionConflict

        /// Attempted to start a transaction whose idempotency key matches one
        /// already in flight.
        case transactionInProgress

        /// AWS reported an internal failure.
        case internalServerError

        /// Service is temporarily unavailable.
        case serviceUnavailable

        // MARK: Non-retryable (business / semantic)

        /// A `ConditionExpression` evaluated to false. Single-item writes
        /// typically surface this as the typed `ConditionalCheckFailed<Model>`
        /// instead.
        case conditionalCheckFailed

        /// Request was syntactically or semantically invalid.
        case validation

        /// Transaction contained two writes targeting the same key.
        case duplicateItem

        /// A local secondary index would exceed its 10GB partition limit.
        case itemCollectionSizeLimitExceeded

        /// Requested table, index, or item does not exist.
        case resourceNotFound

        /// IAM denied the action.
        case accessDenied

        // MARK: Catch-all

        /// Adapter saw a failure it doesn't categorize. The raw AWS code (if
        /// known) is preserved for diagnostics. Treated as non-retryable,
        /// erring on the side of *not* retrying when we don't recognize the
        /// signal.
        case unknown(code: String?)

        /// True for failure modes where retrying the same operation after a
        /// backoff is reasonable.
        public var isRetryable: Bool {
            switch self {
            case .throttled, .throughputExceeded, .transactionConflict,
                 .transactionInProgress, .internalServerError, .serviceUnavailable:
                return true
            case .conditionalCheckFailed, .validation, .duplicateItem,
                 .itemCollectionSizeLimitExceeded, .resourceNotFound, .accessDenied,
                 .unknown:
                return false
            }
        }
    }
}

extension DynamoFailure: DynamoError {
    public var isRetryable: Bool { reason.isRetryable }
}

/// Shared interface across every lambda-kit error type: `DynamoFailure`,
/// `TransactionCanceled`, `ConditionalCheckFailed<Model>`, and
/// `ReturnedAttributesNotFound<Model>` all conform. Lets callers ask "should
/// I retry this?" without knowing which concrete type they caught:
///
///     do {
///         try await operation.execute(using: client)
///     } catch let error as any DynamoError where error.isRetryable {
///         // backoff and retry
///     }
public protocol DynamoError: Error {
    /// True if retrying the same operation after a backoff is reasonable.
    /// False for business-rule failures (condition checks, validation,
    /// duplicate items, auth) and unrecognized errors. Those will fail the
    /// same way every time.
    var isRetryable: Bool { get }
}
