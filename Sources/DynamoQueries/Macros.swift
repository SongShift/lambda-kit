/// Lifts a `Codable` struct into a typed DynamoDB table model.
///
/// Generates a ``DynamoModel`` conformance, the `Columns` proxy that the
/// query/scan/update DSLs hand to your closures, the static `Attributes`
/// namespace, and an `Indexes` enum populated from any sibling
/// ``Index(_:partitionKey:sortKey:)`` declarations.
///
///     @Table("Users")
///     struct User: Codable {
///         @PartitionKey var id: String
///         var displayName: String
///     }
///
/// The string argument is the table name on the wire. Omit it to use the
/// Swift type name as the table name:
///
///     @Table
///     struct User: Codable { ... } // table name is "User"
///
/// Requires exactly one ``PartitionKey()`` property. ``SortKey()``,
/// ``Attribute(_:)``, and ``Index(_:partitionKey:sortKey:)`` are all optional.
@attached(extension, conformances: DynamoModel, names: named(_table), named(Attributes), named(Columns), named(columns), arbitrary)
public macro Table(_ name: String) = #externalMacro(module: "DynamoQueriesMacros", type: "TableMacro")

/// Lifts a `Codable` struct into a typed DynamoDB table model, using the
/// Swift type name as the table name. See ``Table(_:)`` for the customizable
/// form.
@attached(extension, conformances: DynamoModel, names: named(_table), named(Attributes), named(Columns), named(columns), arbitrary)
public macro Table() = #externalMacro(module: "DynamoQueriesMacros", type: "TableMacro")

/// Marks a property as the table's partition key (DynamoDB hash key).
///
/// Required exactly once per ``Table(_:)`` declaration. The marked property
/// becomes the primary-key argument for ``DynamoModel/get(partitionKey:)``,
/// ``DynamoModel/update(partitionKey:_:where:)``, and friends.
@attached(peer)
public macro PartitionKey() = #externalMacro(module: "DynamoQueriesMacros", type: "PartitionKeyMacro")

/// Marks a property as the table's sort key (DynamoDB range key).
///
/// Optional; tables without a sort key use the partition-key-only overloads
/// of `get` / `update` / `delete`. Mixing the two (calling the
/// partition-key-only overload on a table that declares a sort key, or vice
/// versa) throws ``PrimaryKeyError``.
@attached(peer)
public macro SortKey() = #externalMacro(module: "DynamoQueriesMacros", type: "SortKeyMacro")

/// Overrides the DynamoDB attribute name for a property.
///
/// By default, the macro uses the Swift property name as the on-the-wire
/// attribute name. Use `@Attribute("custom_name")` when the DynamoDB schema
/// uses a different casing or convention than the Swift type:
///
///     @Table("Profiles")
///     struct Profile: Codable {
///         @PartitionKey var id: String
///         @Attribute("display_name") var displayName: String
///     }
///
/// This affects expression compilation. Filter and update expressions will
/// use the `@Attribute` value, not the Swift property name.
@attached(peer)
public macro Attribute(_ name: String) = #externalMacro(module: "DynamoQueriesMacros", type: "AttributeMacro")

/// Declares how a property's values are encoded into DynamoDB *expression
/// attribute values* (the `:v0` in `SET #n0 = :v0`), for types that can't
/// conform to `DynamoEncodable` directly (nested `Codable` structs,
/// non-string-keyed dictionaries, …).
///
///     @Table("Lockers")
///     struct Locker: Codable {
///         @PartitionKey var id: String
///         @ExpressionValue(as: GearSlotMapEncoder.self)
///         var slots: [Int: GearSlot]
///     }
///
/// `@Table` generates the column as a ``RepresentedAttribute`` instead of an
/// ``Attribute``, so update actions encode through the representation:
///
///     Locker.update(partitionKey: id) {
///         try $0.slots.set(to: slots)
///     }
///
/// The representation governs expression values only — it plays no part in
/// decoding, and full-item puts and reads still go through the model's own
/// `Codable` conformance, so the two must agree on the wire format.
/// ``DynamoExpressionRepresentation`` documents the contract.
@attached(peer)
public macro ExpressionValue<R: DynamoExpressionRepresentation>(
    as representation: R.Type
) = #externalMacro(module: "DynamoQueriesMacros", type: "ExpressionValueMacro")

/// Declares a secondary index on a `@Table` struct.
///
/// Generates a typed `Indexes.<name>` static instance the query/scan APIs
/// accept via ``QueryInput/usingIndex(_:)``:
///
///     @Table("Users")
///     @Index("emailIndex", partitionKey: "email")
///     struct User: Codable {
///         @PartitionKey var id: String
///         var email: String
///     }
///
///     try await User.query { u in
///         Key { u.email == "ada@example.com" }
///     }
///     .usingIndex(User.Indexes.emailIndex)
///     .execute(using: client)
///
/// Multiple `@Index` declarations are supported on a single table. The
/// macro merges them into the same `Indexes` namespace, and `@Table` exposes
/// them all through the model's static `indexes` array.
///
/// Key names refer to on-the-wire attribute names (the `@Attribute` override
/// when present, the Swift property name otherwise). The macro resolves each
/// one against the model's properties and records its DynamoDB scalar type;
/// `DynamoModel.createTableInput` in `DynamoQueriesSoto` builds `CreateTable`
/// requests from the result.
@attached(peer)
public macro Index(
    _ name: String,
    partitionKey: String,
    sortKey: String? = nil
) = #externalMacro(module: "DynamoQueriesMacros", type: "IndexMacro")

/// Declares a secondary index with multi-attribute keys: up to four
/// attributes hashed together as the partition key, and up to four more as a
/// hierarchical sort key.
///
///     @Table("QuickShareLinks")
///     @Index(
///         "creatorId-isDeleted-isPrivate-isPinned-createdAt-index",
///         partitionKeys: ["creatorId", "isDeleted", "isPrivate", "isPinned"],
///         sortKeys: ["createdAt"]
///     )
///     struct QuickShareLink: Codable { ... }
///
/// DynamoDB requires equality on every partition-key attribute, and sort-key
/// attributes constrained left-to-right with at most one trailing range
/// condition:
///
///     try await QuickShareLink.query { link in
///         Key {
///             link.creatorId == creatorId
///             link.isDeleted == 0
///             link.isPrivate == 0
///             link.isPinned == 1
///             link.createdAt > cutoff
///         }
///     }
///     .usingIndex(QuickShareLink.Indexes.creatorIdIsDeletedIsPrivateIsPinnedCreatedAtIndex)
///     .execute(using: client)
///
/// Key attributes must encode as a DynamoDB scalar (`S`, `N`, or `B`), which
/// the macro checks via ``DynamoKeyEncodable``. `Bool` properties don't
/// qualify because they encode as `BOOL`; store key-participating flags as
/// `Int`. See ``Index(_:partitionKey:sortKey:)`` for the single-attribute
/// form.
@attached(peer)
public macro Index(
    _ name: String,
    partitionKeys: [String],
    sortKeys: [String] = []
) = #externalMacro(module: "DynamoQueriesMacros", type: "IndexMacro")
