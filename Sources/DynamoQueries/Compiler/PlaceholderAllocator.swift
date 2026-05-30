/// Allocates `#nN` (attribute name) and `:vN` (attribute value) placeholders
/// for a single DynamoDB request and accumulates the maps that resolve them.
///
/// One allocator handles every expression on a request (key condition, filter,
/// condition, and update) so their placeholder spaces never collide on a
/// single request that mixes them (the canonical example: `UpdateItem` with
/// both an update expression and a condition expression). Callers create one
/// allocator per input-builder call, hand it `inout` to each compiler in turn,
/// and read `attributeNames` / `attributeValues` out at the end.
public struct PlaceholderAllocator: Sendable {
    private var nameCounter: Int = 0
    private var valueCounter: Int = 0
    public private(set) var attributeNames: [String: String] = [:]
    public private(set) var attributeValues: [String: DynamoValue] = [:]

    public init() {}

    /// Allocate a fresh `#nN` placeholder for the given attribute name and
    /// record the mapping.
    public mutating func name(for attribute: String) -> String {
        let placeholder = "#n\(nameCounter)"
        nameCounter += 1
        attributeNames[placeholder] = attribute
        return placeholder
    }

    /// Allocate a fresh `:vN` placeholder for the given value and record the
    /// mapping.
    public mutating func value(for value: DynamoValue) -> String {
        let placeholder = ":v\(valueCounter)"
        valueCounter += 1
        attributeValues[placeholder] = value
        return placeholder
    }
}
