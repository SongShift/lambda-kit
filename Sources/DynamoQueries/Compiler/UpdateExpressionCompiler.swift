/// Compiles a list of `UpdateAction`s into a single DynamoDB update
/// expression of the form `SET ... REMOVE ... ADD ... DELETE ...`,
/// writing its placeholders into the caller's `PlaceholderAllocator`.
///
/// Sharing the allocator with `ExpressionCompiler` is what lets a conditional
/// update emit one set of `#nN` / `:vN` ids across both the update and
/// condition strings.
public enum UpdateExpressionCompiler {
    public static func compile(
        _ actions: [UpdateAction],
        allocator: inout PlaceholderAllocator
    ) -> String {
        var setClauses: [String] = []
        var removeClauses: [String] = []
        var addClauses: [String] = []
        var deleteClauses: [String] = []

        for action in actions {
            switch action {
            case .set(let attribute, let value):
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: value)
                setClauses.append("\(name) = \(valuePlaceholder)")

            case .setIfNotExists(let attribute, let fallback):
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: fallback)
                setClauses.append("\(name) = if_not_exists(\(name), \(valuePlaceholder))")

            case .listAppend(let attribute, let items):
                // Wrap the existing-list operand in if_not_exists so the
                // expression succeeds even when the attribute is missing.
                // Bare list_append(name, ...) fails with ValidationException
                // if name doesn't exist.
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: items)
                let emptyPlaceholder = allocator.value(for: .list([]))
                setClauses.append("\(name) = list_append(if_not_exists(\(name), \(emptyPlaceholder)), \(valuePlaceholder))")

            case .listPrepend(let attribute, let items):
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: items)
                let emptyPlaceholder = allocator.value(for: .list([]))
                setClauses.append("\(name) = list_append(\(valuePlaceholder), if_not_exists(\(name), \(emptyPlaceholder)))")

            case .remove(let attribute):
                removeClauses.append(allocator.name(for: attribute))

            case .add(let attribute, let value):
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: value)
                addClauses.append("\(name) \(valuePlaceholder)")

            case .delete(let attribute, let value):
                let name = allocator.name(for: attribute)
                let valuePlaceholder = allocator.value(for: value)
                deleteClauses.append("\(name) \(valuePlaceholder)")
            }
        }

        var parts: [String] = []
        if !setClauses.isEmpty { parts.append("SET " + setClauses.joined(separator: ", ")) }
        if !removeClauses.isEmpty { parts.append("REMOVE " + removeClauses.joined(separator: ", ")) }
        if !addClauses.isEmpty { parts.append("ADD " + addClauses.joined(separator: ", ")) }
        if !deleteClauses.isEmpty { parts.append("DELETE " + deleteClauses.joined(separator: ", ")) }

        return parts.joined(separator: " ")
    }
}
