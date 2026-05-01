# ``DynamoQueries``

A typed, expressive query DSL for DynamoDB, with macros that lift your table schema into the type system.

## Overview

`DynamoQueries` lets you describe DynamoDB operations against typed Swift
models. The ``Table(_:)`` macro generates an ``DynamoModel`` conformance and a
nested `Columns` proxy whose properties are typed ``Attribute`` references —
so query and update expressions are checked at compile time and rendered to
DynamoDB-correct expression strings at runtime.

```swift
@Table("Users")
@Index("emailIndex", partitionKey: "email")
struct User: Codable {
    @PartitionKey var id: String
    var email: String
    var displayName: String
    var createdAt: Date
    var loginCount: Int = 0
}

let firstPage = try await User.query { user in
    Key { user.id == "user-123" }
}
.execute(using: client)
```

The library is split into three concerns:

  * **Schema declaration.** The ``Table(_:)``, ``PartitionKey()``,
    ``SortKey()``, ``Attribute(_:)``, and ``Index(_:partitionKey:sortKey:)``
    macros declare the shape of a table. They generate everything the runtime
    needs to compile expressions and decode responses.
  * **Operation builders.** ``QueryInput``, ``ScanInput``, ``GetItemInput``,
    ``PutItemInput``, ``UpdateInput``, ``DeleteItemInput``, ``BatchGetInput``,
    ``BatchWriteInput``, and ``TransactWriteInput`` describe the operations
    you'll issue against the table. Each is built through a result-builder DSL
    and configured through chainable modifiers.
  * **Wire transport.** A ``DynamoClient`` adapter ships requests over the wire.
    The companion `DynamoQueriesSoto` product provides `SotoDynamoClient` for
    real DynamoDB; tests typically use a recording mock.

> Note: For an end-to-end tour of the operations, see <doc:Operations>.
> For schema design with macros, see <doc:Schema>.

## Quick start

Declare your schema:

```swift
@Table("Orders")
@Index("byCreatedAt", partitionKey: "customerID", sortKey: "createdAt")
struct Order: Codable {
    @PartitionKey var customerID: String
    @SortKey var orderID: String
    var createdAt: Double
    var total: Double
    var status: String
}
```

Issue a query:

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
.on(Order.Indexes.byCreatedAt)
.scanIndexForward(false)
.limit(20)
.execute(using: client)
```

Issue a transactional write:

```swift
try await TransactWriteInput {
    order.put { $0.orderID.doesNotExist }
    try Customer.update(partitionKey: order.customerID) {
        $0.lifetimeValue.add(order.total)
    }
}
.execute(using: client)
```

## Topics

### Essentials

- <doc:Schema>
- <doc:Operations>
- <doc:WireTransport>

### Declaring tables

- ``Table(_:)``
- ``PartitionKey()``
- ``SortKey()``
- ``Attribute(_:)``
- ``Index(_:partitionKey:sortKey:)``
- ``DynamoModel``
- ``TableMetadata``
- ``Index``

### Attributes and expressions

- ``Attribute``
- ``AttributeReference``
- ``Expression``
- ``SizeExpression``
- ``SizeComparisonOp``
- ``DynamoSizable``

### Reads

- ``QueryInput``
- ``ScanInput``
- ``GetItemInput``
- ``BatchGetInput``
- ``QueryPage``
- ``CountPage``
- ``PaginationToken``
- ``QueryPageSequence``
- ``ScanPageSequence``

### Writes

- ``PutItemInput``
- ``UpdateInput``
- ``UpdateReturning``
- ``UpdateReturnValues``
- ``UpdateAction``
- ``DeleteItemInput``
- ``BatchWriteInput``
- ``TransactWriteInput``
- ``TransactWriteItem``

### Result builders

- ``Key``
- ``Filter``
- ``QueryParts``
- ``QueryBuilder``
- ``KeyConditionBuilder``
- ``FilterBuilder``
- ``ConditionBuilder``
- ``UpdateBuilder``
- ``TransactWriteBuilder``

### Wire types

- ``DynamoValue``
- ``DynamoEncodable``
- ``DynamoSetElement``
- ``DynamoAttributeType``

### Transport

- ``DynamoClient``

### Errors

- ``ConditionalCheckFailed``
- ``TransactionCanceled``
- ``PrimaryKeyError``
