# Declaring tables

Use macros to lift your DynamoDB schema into the Swift type system.

## Overview

The ``Table(_:)`` macro is the entry point. Apply it to a `Codable` struct
together with ``PartitionKey()`` (required), optionally ``SortKey()``, and
zero or more ``Index(_:partitionKey:sortKey:)`` declarations:

```swift
@Table("Users")
@Index("emailIndex", partitionKey: "email")
@Index("byCreatedAt", partitionKey: "tenantID", sortKey: "createdAt")
struct User: Codable {
    @PartitionKey var id: String
    var tenantID: String
    var email: String
    var displayName: String
    var createdAt: Date
    var loginCount: Int = 0
    var isVerified: Bool = false
}
```

The string argument is the table name on the wire. Omit it to use the
Swift type name as the table name:

```swift
@Table                       // table name is "User"
struct User: Codable {
    @PartitionKey var id: String
}
```

The macro generates four things:

  * A ``DynamoModel`` conformance.
  * A static `_table` ``TableMetadata`` value carrying the runtime schema —
    table name, partition key, optional sort key.
  * A nested `Columns` struct (one ``Attribute`` per declared property) plus
    a static `Attributes` enum and a generated `$name` accessor for each
    attribute.
  * A nested `Indexes` enum with one ``Index`` value per `@Index`
    declaration.

## Property attributes

  * ``PartitionKey()`` — exactly one per table. Marks the property as the
    table's hash key.
  * ``SortKey()`` — optional. Marks the property as the table's range key.
  * ``Attribute(_:)`` — overrides the on-the-wire attribute name. Useful when
    you want to use a Swift-idiomatic property name (`displayName`) for an
    attribute stored under a different DynamoDB name (`display_name`).

```swift
@Table("Profiles")
struct Profile: Codable {
    @PartitionKey var id: String
    @Attribute("display_name") var displayName: String
}
```

## Indexes

`@Index(_:partitionKey:sortKey:)` declares a secondary index. The macro
generates a typed ``Index`` value at `Self.Indexes.<name>` that you pass to
``QueryInput/usingIndex(_:)`` (or the scan equivalent) to retarget a query at the
index:

```swift
let page = try await User.query { u in
    Key { u.email == "ada@example.com" }
}
.usingIndex(User.Indexes.emailIndex)
.execute(using: client)
```

The library doesn't try to type-check that the index's partition or sort key
attribute names match your declared properties. DynamoDB lets indexes
project arbitrary subsets and even synthetic attributes, so the partition/sort
keys are just strings on the wire.

## What `Columns` looks like

For the `User` example above, the macro generates roughly:

```swift
extension User: DynamoModel {
    public static let _table = TableMetadata(
        name: "Users",
        partitionKey: "id",
        sortKey: nil
    )

    public struct Columns: Sendable {
        public let id          = Attribute<String>("id")
        public let tenantID    = Attribute<String>("tenantID")
        public let email       = Attribute<String>("email")
        public let displayName = Attribute<String>("displayName")
        public let createdAt   = Attribute<Date>("createdAt")
        public let loginCount  = Attribute<Int>("loginCount")
        public let isVerified  = Attribute<Bool>("isVerified")
    }
    public static let columns = Columns()

    public enum Indexes {
        public static let emailIndex = Index<User>(name: "emailIndex", partitionKey: "email")
        public static let byCreatedAt = Index<User>(name: "byCreatedAt", partitionKey: "tenantID", sortKey: "createdAt")
    }
}
```

`columns` is what gets passed into the closure parameter of `query`, `scan`,
`update`, and friends — so call sites read `column.email == "..."` rather
than `User.$email == "..."`.

## Encoding

Models are encoded and decoded via `Codable`. The `DynamoQueriesSoto`
adapter uses Soto's native `DynamoDBEncoder` / `DynamoDBDecoder` (with
`secondsSince1970` date strategy), so values land in their native
DynamoDB attribute types — strings, numbers, booleans, lists, and nested
maps — rather than going through a JSON intermediate.

If you need a property name on the wire that differs from the Swift
property name, prefer ``Attribute(_:)`` over `CodingKeys` — the
`@Attribute("name")` annotation is what the expression compiler uses, so
filters and updates need it to be set correctly.
