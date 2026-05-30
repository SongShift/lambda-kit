# Operations

Issue queries, scans, gets, puts, updates, deletes, batch operations, and transactional writes.

## Overview

Every operation against DynamoQueries follows the same shape:

  1. Build an input value via a static method on your model
     (``DynamoModel/query(_:)``, ``DynamoModel/scan(_:)``,
     ``DynamoModel/get(partitionKey:)``, etc.).
  2. Configure it with chainable modifiers (`.usingIndex(_:)`, `.limit(_:)`,
     `.consistentRead()`, …).
  3. Call `.execute(using: client)` to fire the request.

The input types are `Sendable` value types, so they can be stored,
transformed, and reused. `.execute(using:)` is the only step that does I/O.

## Query

Reach for ``QueryInput`` whenever your access pattern can constrain the
partition key. Compose the key condition inside a ``Key`` block and any
post-fetch filter inside a ``Filter`` block:

```swift
let page = try await Order.query { o in
    Key {
        o.customerID == "cust-1"
        o.orderID.beginsWith("2026-")
    }
    Filter {
        o.status != "cancelled"
        o.total > 100
    }
}
.execute(using: client)
```

Common modifiers:

  * ``QueryInput/usingIndex(_:)``: run the query against a secondary index.
  * ``QueryInput/limit(_:)``: cap per-request page size.
  * ``QueryInput/consistentRead(_:)``: strongly consistent reads (doubles
    read-capacity cost; rejected on global secondary indexes).
  * ``QueryInput/scanIndexForward(_:)``: `false` walks the sort key in
    descending order.
  * `QueryInput.project(_:)`: restrict the response to a subset of
    attributes.

## Scan

Use ``ScanInput`` only when no access pattern constrains the partition key.
DynamoDB applies the filter *after* reading the page from disk, so a
filtered scan still bills for the unfiltered read.

```swift
let pending = try await Order.scan { o in
    o.status == "pending"
}
.executeAll(using: client)
```

## Get / Put / Update / Delete

Single-item operations are addressed by primary key. The `@Table` macro
generates exactly the overload that matches your table's key shape:
`get(partitionKey:)` for a partition-only table, `get(partitionKey:sortKey:)`
for a composite-key table. Passing the wrong key arity is a compile error, not
a runtime failure, so these factories don't throw and don't need a `try`.

```swift
// GET
let user = try await User.get(partitionKey: "user-123").execute(using: client)

// PUT (insert-or-replace)
try await user.put().execute(using: client)

// PUT (insert-only-if-not-present)
try await user.put { $0.id.doesNotExist }.execute(using: client)

// UPDATE
try await User.update(
    partitionKey: "user-123",
    {
        $0.displayName.set(to: "Ada")
        $0.loginCount.add(1)
        $0.createdAt.setIfNotExists(.now)
    },
    where: { $0.id.exists }
)
.execute(using: client)

// DELETE
try await User.delete(partitionKey: "user-123").execute(using: client)
```

### Conditional checks

Every write supports a `where:` (or condition) block. When the condition
fails, the adapter throws ``ConditionalCheckFailed`` typed against the
model. Add ``PutItemInput/returnConflictingItem(_:)`` (or the equivalent on
update/delete) to have DynamoDB return the conflicting prior item:

```swift
do {
    try await user
        .put { $0.id.doesNotExist }
        .returnConflictingItem()
        .execute(using: client)
} catch let conflict as ConditionalCheckFailed<User> {
    let existing = conflict.priorItem  // Optional<User>, nil when not requested
}
```

### Returning updated values

``UpdateInput`` has four `return*` modifiers that wrap it in an
``UpdateReturning`` whose `execute(using:)` returns `Model?` instead of
`Void`:

  * ``UpdateInput/returnNewValues()``: the entire item, post-update.
  * ``UpdateInput/returnOldValues()``: the entire item, pre-update.
  * ``UpdateInput/returnUpdatedNewValues()``: only the touched attributes,
    post-update.
  * ``UpdateInput/returnUpdatedOldValues()``: only the touched attributes,
    pre-update.

The two "updated" variants may produce items missing fields the model
declares as non-optional; model only-this-update fields as optional, or the
decode will fail.

## Batch operations

``BatchGetInput`` and ``BatchWriteInput`` are single-table batch operations.
Adapters auto-retry the `UnprocessedKeys` / `UnprocessedItems` portion of
each response until the remainder is empty, so callers see the full result
set as a single async call.

```swift
let users = try await User.batchGet(partitionKeys: ["a", "b", "c"]).execute(using: client)

try await User.batchWrite()
    .put(userA)
    .put(userB)
    .delete(partitionKey: "user-deprecated")
    .execute(using: client)
```

Batch writes don't honor condition expressions. Reach for
``TransactWriteInput`` if you need atomicity.

## Transactional writes

``TransactWriteInput`` describes an atomic, all-or-nothing multi-item
write. Up to 100 legs per transaction; each leg can target a different
table. Build with the ``TransactWriteBuilder`` result builder:

```swift
try await TransactWriteInput {
    user.put { $0.id.doesNotExist }
    Account.update(partitionKey: user.id) { $0.userCount.add(1) }
    try AuditLog.conditionCheck(partitionKey: "system") { $0.frozen != true }
}
.execute(using: client)
```

A failed transaction throws ``TransactionCanceled``. The
`cancellations` array maps 1:1 to the legs you submitted, with `code` and
`message` per leg. Legs that succeeded carry `code == "None"`. The leg that
failed will have a code like `"ConditionalCheckFailed"` or
`"TransactionConflict"`.

`ConditionalCheckFailed` is **not** thrown for transactional failures.
DynamoDB returns a single transaction-canceled exception even when only one
leg's condition failed.

### Composing transactions

Every write builder (``PutItemInput``, ``UpdateInput``, ``DeleteItemInput``)
and ``TransactWriteInput`` itself conforms to ``TransactWritable``. The
result builder accepts any value of that protocol (including arrays of
writables via the conditional `Array: TransactWritable` conformance) and
flattens them into a single leg list. Three things this unlocks:

1. **Write builders are values, not async calls.** A method can build the
   write and hand it back; the caller decides whether to fire it on its own
   or fold it into a larger transaction.
2. **Multi-leg returns.** A function can return a nested
   ``TransactWriteInput`` (or `[any TransactWritable]`) and the outer
   builder unrolls every leg in place.
3. **Repositories own state shape, not transaction boundaries.** Push the
   atomic-boundary decision up to the service layer where it belongs.

A repository example:

```swift
struct HikerRepository {
    // Single leg.
    func create(_ hiker: Hiker) -> any TransactWritable {
        hiker.put { $0.id.doesNotExist }
    }

    // Multi-leg: nested TransactWriteInput is itself a TransactWritable.
    func logHike(_ hike: Hike) -> any TransactWritable {
        TransactWriteInput {
            hike.put { $0.hikeID.doesNotExist }
            Hiker.update(partitionKey: hike.hikerID) {
                $0.hikeCount.add(1)
            } where: { $0.id.exists }
        }
    }

    // Homogeneous list, flattens via Array's conditional conformance.
    func cancel(_ hikes: [(hikerID: String, hikeID: String)]) -> any TransactWritable {
        hikes.map { ids in
            Hike.update(partitionKey: ids.hikerID, sortKey: ids.hikeID) {
                $0.status.set(to: "cancelled")
            }
        }
    }
}
```

Composing at the call site:

```swift
try await TransactWriteInput {
    repo.create(newHiker)            // 1 leg
    repo.logHike(recordedHike)       // 2 legs (nested TransactWriteInput)
    repo.cancel(staleHikes)          // N legs (array of UpdateInput)
}
.execute(using: client)
```

The builder doesn't care whether each line resolves to one leg or many.
It asks the value for `toTransactWriteItems()` and concatenates the
results. The 100-leg per-transaction limit applies to the flattened total,
so a multi-leg method counts against the same budget as a single-leg one.

## Pagination

Single page, opaque cursor in the response:

```swift
let page = try await Order.query { ... }.execute(using: client)
let nextCursor = page.nextToken?.stringValue  // safe to embed in JSON
```

Stream every page lazily:

```swift
for try await page in Order.query { ... }.pages(using: client) {
    process(page.items)
}
```

Buffer all pages into an array (be careful with unbounded result sets):

```swift
let all = try await Order.query { ... }.executeAll(using: client)
```

Count without retrieving items (cheaper because the items don't cross the
wire, though DynamoDB still bills RCU for items the filter touched):

```swift
let n = try await Order.query { ... }.count(using: client)
```
