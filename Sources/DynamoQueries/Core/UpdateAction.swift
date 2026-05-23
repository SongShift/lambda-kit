/// A single clause in a DynamoDB update expression.
///
/// `UpdateAction` is the update-time analogue of `Expression`: it's the
/// transport-neutral data the compiler turns into a `SET ... REMOVE ... ADD
/// ... DELETE ...` string. Each case maps directly to one DynamoDB clause:
///
/// - `set` / `setIfNotExists` / `listAppend` / `listPrepend` → `SET`
/// - `remove` → `REMOVE`
/// - `add` → `ADD` (atomic numeric increment, or set element add)
/// - `delete` → `DELETE` (set element remove)
public enum UpdateAction: Sendable, Equatable {
    case set(attributeName: String, value: DynamoValue)
    case setIfNotExists(attributeName: String, fallback: DynamoValue)
    /// `SET name = list_append(if_not_exists(name, :empty), :items)` —
    /// appends `items` to the end of the list, creating the list if the
    /// attribute is missing so the expression succeeds either way.
    case listAppend(attributeName: String, items: DynamoValue)
    /// `SET name = list_append(:items, if_not_exists(name, :empty))` —
    /// prepends `items` to the front of the list, creating the list if the
    /// attribute is missing so the expression succeeds either way.
    case listPrepend(attributeName: String, items: DynamoValue)
    case remove(attributeName: String)
    case add(attributeName: String, value: DynamoValue)
    case delete(attributeName: String, value: DynamoValue)
}
