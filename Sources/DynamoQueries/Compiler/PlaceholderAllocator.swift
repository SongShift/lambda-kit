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
    ///
    /// Dots are treated as document-path separators: each component gets its
    /// own placeholder and the components are rejoined with `.`, so
    /// `lock.lockedUntil` renders as `#n0.#n1` — a path into the map. (A
    /// single shared placeholder would be substituted by DynamoDB as a
    /// literal attribute *name* containing a dot, never a path.) The
    /// trade-off: attribute names containing a literal `.` can't be
    /// addressed through the DSL; build those requests with the raw input
    /// initializers instead.
    public mutating func name(for attribute: String) -> String {
        attribute
            .split(separator: ".")
            .map { component in
                let placeholder = "#n\(nameCounter)"
                nameCounter += 1
                attributeNames[placeholder] = String(component)
                return placeholder
            }
            .joined(separator: ".")
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
