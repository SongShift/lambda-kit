import DynamoQueries

/// Run `operation` against a real `DynamoClient`, asserting it fails with a
/// ``ConditionalCheckFailed`` parameterized by `Model`. Returns the typed
/// error so the caller can inspect `priorItem` and friends with whatever
/// testing framework they prefer.
///
/// Intended for integration tests that hit real DynamoDB: seed a row, attempt
/// a conflicting write, then call this helper to drive the failure path
/// without re-writing the catch/cast boilerplate every time.
///
///     let priorUser = User(id: "u-1", version: 1)
///     try await client.putItem(priorUser.put())
///
///     let failure = try await expectConditionalCheckFailure(of: User.self) {
///         try await User(id: "u-1", version: 99)
///             .put { $0.version == 42 }
///             .returnConflictingItem()
///             .execute(using: client)
///     }
///
///     #expect(failure.priorItem?.version == 1)
///
/// If `operation` returns normally, the helper throws
/// ``TestExpectationFailure/operationDidNotThrow``. If it throws any other
/// error type, that error propagates unchanged. The test will fail with
/// the original error's diagnostic, so you can tell "wrong error" apart from
/// "no error".
public func expectConditionalCheckFailure<Model: DynamoModel>(
    of type: Model.Type,
    when operation: () async throws -> Void
) async throws -> ConditionalCheckFailed<Model> {
    do {
        try await operation()
    } catch let failure as ConditionalCheckFailed<Model> {
        return failure
    }
    throw TestExpectationFailure.operationDidNotThrow(
        expected: "ConditionalCheckFailed<\(Model.self)>"
    )
}

/// Run `operation` against a real `DynamoClient`, asserting it fails with a
/// ``TransactionCanceled``. Returns the typed error so the caller can iterate
/// `failedCancellations`, inspect each leg's ``DynamoFailure``, or decode
/// `priorRawItem` as needed.
///
/// Same semantics as ``expectConditionalCheckFailure(of:when:)``: if the
/// operation succeeds, throws ``TestExpectationFailure/operationDidNotThrow``;
/// if it throws a different error, that error propagates unchanged.
///
///     let cancellation = try await expectTransactionCancellation {
///         try await TransactWriteInput {
///             newOrder.put { $0.id.doesNotExist }
///             try Inventory.update(partitionKey: sku) { $0.stock.add(-1) }
///                 where: { $0.stock >= 1 }
///         }
///         .execute(using: client)
///     }
///
///     #expect(cancellation.failedCancellations.count == 1)
///     #expect(cancellation.failedCancellations[0].failure?.reason == .conditionalCheckFailed)
public func expectTransactionCancellation(
    when operation: () async throws -> Void
) async throws -> TransactionCanceled {
    do {
        try await operation()
    } catch let cancellation as TransactionCanceled {
        return cancellation
    }
    throw TestExpectationFailure.operationDidNotThrow(expected: "TransactionCanceled")
}

/// Run `operation`, asserting it throws a ``DynamoFailure`` whose `reason`
/// matches `reason`. Returns the failure so the caller can inspect its
/// `message` or `isRetryable`. Pairs naturally with `FailingDynamoClient`:
///
///     let failure = try await expectDynamoFailure(.throttled) {
///         try await service.refresh(using: FailingDynamoClient(reason: .throttled))
///     }
///     #expect(failure.isRetryable)
///
/// Same semantics as the other `expect*` helpers: if `operation` returns
/// without throwing, throws ``TestExpectationFailure/operationDidNotThrow``; if
/// it throws a different error, or a `DynamoFailure` with a *different* reason,
/// that error propagates unchanged, so a wrong reason is distinguishable from a
/// missing throw.
public func expectDynamoFailure(
    _ reason: DynamoFailure.Reason,
    when operation: () async throws -> Void
) async throws -> DynamoFailure {
    do {
        try await operation()
    } catch let failure as DynamoFailure where failure.reason == reason {
        return failure
    }
    throw TestExpectationFailure.operationDidNotThrow(expected: "DynamoFailure(reason: .\(reason))")
}

/// Run `operation`, asserting it throws an error of type `E`. Returns the typed
/// error for further inspection. The generic catch-all behind the typed
/// helpers. Use it for your own error types or when the specific lambda-kit
/// helper doesn't apply.
///
///     let error = try await expectError(MyServiceError.self) {
///         try await service.run(using: FailingDynamoClient(reason: .accessDenied))
///     }
///
/// Same semantics as the other `expect*` helpers: no throw →
/// ``TestExpectationFailure/operationDidNotThrow``; a different error type
/// propagates unchanged.
public func expectError<E: Error>(
    _ type: E.Type,
    when operation: () async throws -> Void
) async throws -> E {
    do {
        try await operation()
    } catch let error as E {
        return error
    }
    throw TestExpectationFailure.operationDidNotThrow(expected: "\(E.self)")
}

/// Error type used by the `expect*` helpers when an operation was expected
/// to throw a specific lambda-kit error but instead returned normally. A
/// mismatched error type isn't surfaced as a `TestExpectationFailure`. The
/// original error propagates so the failure diagnostic carries its full
/// context.
public enum TestExpectationFailure: Error, CustomStringConvertible, Sendable {
    case operationDidNotThrow(expected: String)

    public var description: String {
        switch self {
        case .operationDidNotThrow(let expected):
            return "expected operation to throw \(expected); it returned without throwing"
        }
    }
}
