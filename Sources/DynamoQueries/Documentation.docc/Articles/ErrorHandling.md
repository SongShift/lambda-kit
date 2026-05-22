# Error handling

A composable, adapter-agnostic vocabulary for failures from `DynamoClient`
operations.

## Overview

Every error a `DynamoQueries` operation throws is one of three types — and
all three conform to ``DynamoError``, so callers can write one branch that
asks "should I retry this?" without knowing which concrete type they caught.

The three types form a layered hierarchy:

  * ``DynamoFailure`` is the **flat, categorized** failure. It carries a
    ``DynamoFailure/Reason`` (throttling, capacity, validation, …) and an
    optional human-readable `message`. Adapters map their native errors into
    this struct — callers never need to import the adapter to interpret a
    failure.
  * ``TransactionCanceled`` is thrown when a multi-leg transaction is
    rolled back. It carries one ``TransactionCanceled/Cancellation`` per leg,
    each holding a ``DynamoFailure`` (or `nil` for legs that succeeded).
    Use this when you need to know *which* leg failed.
  * ``ConditionalCheckFailed`` is thrown for single-item conditional writes
    whose `where:` clause evaluated to false. It carries a typed `priorItem`
    when the request asked for it via `.returnConflictingItem()`.

The shared ``DynamoError`` protocol gives all three a uniform
`isRetryable: Bool`. This is the recommended way to write retry logic — it
will keep working if a future operation type introduces a fourth error
shape.

```swift
do {
    try await operation.execute(using: client)
} catch let error as any DynamoError where error.isRetryable {
    // throttling, capacity, transaction conflict — back off and retry
} catch let conflict as ConditionalCheckFailed<MyModel> {
    // business-rule failure — recover with conflict.priorItem
} catch {
    // anything else is non-retryable; surface or rethrow
}
```

## The DynamoFailure vocabulary

``DynamoFailure/Reason`` is a closed set of categories. The retryable cases
correspond to transient/contention conditions where backing off and trying
again has a real chance of succeeding:

| Reason | Retryable |
| --- | :---: |
| `throttled` | ✓ |
| `throughputExceeded` | ✓ |
| `transactionConflict` | ✓ |
| `transactionInProgress` | ✓ |
| `internalServerError` | ✓ |
| `serviceUnavailable` | ✓ |
| `conditionalCheckFailed` | |
| `validation` | |
| `duplicateItem` | |
| `itemCollectionSizeLimitExceeded` | |
| `resourceNotFound` | |
| `accessDenied` | |
| `unknown(code:)` | |

`.unknown` is the escape hatch. Adapters use it for codes lambda-kit
doesn't categorize — the raw AWS code (if any) is preserved for diagnostics.
It's classified as non-retryable to err on the side of *not* retrying when
the signal is ambiguous.

### Branching on a reason

`DynamoFailure.Reason` is `Equatable`, so pattern-matching reads naturally:

```swift
do {
    try await user.put().execute(using: client)
} catch let failure as DynamoFailure {
    switch failure.reason {
    case .accessDenied:
        throw AuthError.forbidden
    case .resourceNotFound:
        throw AppError.tableMissing
    case .validation:
        logger.error("bad query: \(failure.message ?? "")")
        throw AppError.internalError
    default:
        throw failure
    }
}
```

## Transactions: per-leg failure context

When a transaction is cancelled, ``TransactionCanceled`` reports what
happened to each leg in submission order. DynamoDB returns a cancellation
entry for every leg — including legs that succeeded — so the API exposes a
``TransactionCanceled/failedCancellations`` convenience that filters out
the no-op entries.

```swift
do {
    try await TransactWriteInput {
        order.put { $0.orderID.doesNotExist }
        try Inventory.update(partitionKey: order.sku) { $0.stock.add(-1) }
    }
    .execute(using: client)
} catch let cancellation as TransactionCanceled {
    for failed in cancellation.failedCancellations {
        switch failed.failure?.reason {
        case .conditionalCheckFailed where failed.index == 0:
            // duplicate order — refetch and bail out
        case .conditionalCheckFailed where failed.index == 1:
            // inventory ran out — surface to caller
        default:
            break
        }
    }
}
```

`TransactionCanceled.isRetryable` returns `true` only when *every*
recognized leg is retryable — a single non-retryable leg (a failed
condition, validation, auth denial) makes the transaction definitively
not worth retrying.

> Note: `Cancellation.priorRawItem` is exposed as a raw
> `[String: DynamoValue]` map rather than a typed model — a transaction can
> span tables, so there's no single `Model` that fits every leg. Decode by
> hand if you need the typed item.

## Conditional checks on single-item writes

For non-transactional puts, updates, and deletes whose `where:` clause
evaluates to false, the adapter translates the failure into a typed
``ConditionalCheckFailed`` parameterized by the model. This is the only
error type that carries a *typed* decoded prior item, which is the key
substrate for optimistic-concurrency retry patterns:

```swift
do {
    try await user
        .put { $0.version == previousVersion }
        .returnConflictingItem()
        .execute(using: client)
} catch let conflict as ConditionalCheckFailed<User> {
    // `priorItem` is the User that was actually on the row when our condition
    // ran. Merge in our changes and retry.
    let resolved = merge(local: user, remote: conflict.priorItem)
    try await resolved.put { $0.version == conflict.priorItem?.version }.execute(using: client)
}
```

`priorItem` is `nil` when the request was *not* built with
`.returnConflictingItem()`, when the prior item failed to decode as `Model`
(schema drift), or when DynamoDB didn't carry the item in the
extended-error payload.

`ConditionalCheckFailed` is intentionally **not** thrown for
*transactional* conditional failures — those surface inside
``TransactionCanceled`` as a leg cancellation with
``DynamoFailure/Reason/conditionalCheckFailed`` and an untyped
`priorRawItem`. A transaction can target many models; there's no single
`<Model>` to parameterize the wrapper on.

## Testing error paths

The `DynamoQueriesTestSupport` product ships small wrappers aimed at
integration tests — the ones that hit a real DynamoDB and need to assert
that a specific failure mode was raised.

``expectConditionalCheckFailure(of:when:)`` runs the operation, catches the
typed ``ConditionalCheckFailed`` (or rethrows anything else), and hands the
typed error back for assertion. That removes the catch/cast/`Issue.record`
boilerplate that otherwise repeats in every test:

```swift
import DynamoQueriesTestSupport

let priorUser = User(id: "u-1", version: 1)
try await client.putItem(priorUser.put())

let failure = try await expectConditionalCheckFailure(of: User.self) {
    try await User(id: "u-1", version: 99)
        .put { $0.version == 42 }
        .returnConflictingItem()
        .execute(using: client)
}

#expect(failure.priorItem?.version == 1)
```

The same pattern works for transaction cancellations via
``expectTransactionCancellation(when:)``. Both helpers are pure Swift —
they don't depend on Swift Testing or XCTest, so they fit any test runner.

If the operation surprises the test by *not* throwing, the helper raises a
``TestExpectationFailure``. A mismatched error type is rethrown unchanged so
the diagnostic carries the original context.

## Adapter contract

A custom ``DynamoClient`` adapter is responsible for mapping its native
error types into the lambda-kit taxonomy at the adapter boundary. Callers
should never see an SDK-specific error type leak through.

The `DynamoQueriesSoto` adapter does this with two layered translators:

  1. Specific typed-payload translators run first —
     `translatingConditionalCheckFailures` lifts Soto's
     `conditionalCheckFailedException` into ``ConditionalCheckFailed`` (with
     decoded prior item), and `translatingTransactionFailures` lifts
     `transactionCanceledException` into ``TransactionCanceled`` (with
     per-leg ``DynamoFailure`` reasons).
  2. A generic outer translator (`translatingDynamoFailures`) catches any
     remaining `DynamoDBErrorType` and maps it to a flat ``DynamoFailure``.

Custom adapters follow the same shape: translate the specific cases that
benefit from typed payload first, then catch-all-remaining into
``DynamoFailure``. Use ``DynamoFailure/Reason/unknown(code:)`` as the
fallback for codes you don't categorize — that keeps the SDK error
boxed-in for diagnostics while still preserving the protocol surface.

## Topics

### Shared vocabulary

- ``DynamoFailure``
- ``DynamoError``

### Typed-payload errors

- ``ConditionalCheckFailed``
- ``TransactionCanceled``

### Other

- ``PrimaryKeyError``
