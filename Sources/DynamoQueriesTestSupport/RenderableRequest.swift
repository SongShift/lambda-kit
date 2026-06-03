import DynamoQueries
import Foundation

/// A DynamoDB request that can render itself to a deterministic, human-readable
/// string
public protocol RenderableRequest {
    var renderedRequest: String { get }
}


public enum RequestRender {
    /// One attribute value, e.g. `S("ada")`, `N(5)`, `L[S("a"), N(1)]`,
    /// `M{a: S("x")}`. Sets and maps are sorted so the output is deterministic.
    public static func value(_ value: DynamoValue) -> String {
        switch value {
        case .string(let s): return "S(\"\(s)\")"
        case .number(let n): return "N(\(n))"
        case .bool(let b): return "BOOL(\(b))"
        case .null: return "NULL"
        case .binary(let d): return "B(\(d.base64EncodedString()))"
        case .list(let xs):
            return "L[" + xs.map(Self.value).joined(separator: ", ") + "]"
        case .map(let m):
            return "M{" + sortedPairs(m).joined(separator: ", ") + "}"
        case .stringSet(let s):
            return "SS[" + s.sorted().map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        case .numberSet(let s):
            return "NS[" + s.sorted().joined(separator: ", ") + "]"
        case .binarySet(let s):
            return "BS[" + s.map { $0.base64EncodedString() }.sorted().joined(separator: ", ") + "]"
        }
    }

    /// A `[String: DynamoValue]` map rendered with keys sorted: `{ a: S("x") }`.
    public static func valueMap(_ map: [String: DynamoValue]) -> String {
        "{ " + sortedPairs(map).joined(separator: ", ") + " }"
    }

    /// A `[String: String]` name map rendered with keys sorted: `{ #a: name }`.
    public static func nameMap(_ map: [String: String]) -> String {
        "{ " + map.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ") + " }"
    }

    /// Render a `Codable` item as sorted-key JSON, so a `put`'s payload shows up
    /// stably in a snapshot. 
    public static func item(_ item: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(item), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: item)
    }

    private static func sortedPairs(_ map: [String: DynamoValue]) -> [String] {
        map.sorted { $0.key < $1.key }.map { "\($0.key): \(value($0.value))" }
    }
}

private func renderLines(_ header: String, _ fields: [(String, String?)]) -> String {
    var out = header
    for (label, value) in fields {
        guard let value, !value.isEmpty else { continue }
        out += "\n  \(label): \(value)"
    }
    return out
}

// MARK: - Conformances

extension QueryInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("Query \(tableName)" + (indexName.map { " on \($0)" } ?? ""), [
            ("key", keyConditionExpression),
            ("filter", filterExpression),
            ("names", expressionAttributeNames.isEmpty ? nil : RequestRender.nameMap(expressionAttributeNames)),
            ("values", expressionAttributeValues.isEmpty ? nil : RequestRender.valueMap(expressionAttributeValues)),
            ("project", projectionAttributes.map { $0.joined(separator: ", ") }),
            ("scanForward", scanIndexForward.map(String.init)),
            ("consistentRead", consistentRead ? "true" : nil),
            ("limit", limit.map(String.init)),
            ("select", selectCountOnly ? "COUNT" : nil),
        ])
    }
}

extension ScanInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("Scan \(tableName)" + (indexName.map { " on \($0)" } ?? ""), [
            ("filter", filterExpression),
            ("names", expressionAttributeNames.isEmpty ? nil : RequestRender.nameMap(expressionAttributeNames)),
            ("values", expressionAttributeValues.isEmpty ? nil : RequestRender.valueMap(expressionAttributeValues)),
            ("project", projectionAttributes.map { $0.joined(separator: ", ") }),
            ("consistentRead", consistentRead ? "true" : nil),
            ("limit", limit.map(String.init)),
            ("select", selectCountOnly ? "COUNT" : nil),
        ])
    }
}

extension GetItemInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("GetItem \(tableName)", [
            ("key", RequestRender.valueMap(key)),
            ("project", projectionAttributes.map { $0.joined(separator: ", ") }),
            ("consistentRead", consistentRead ? "true" : nil),
        ])
    }
}

extension PutItemInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("PutItem \(tableName)", [
            ("item", RequestRender.item(item)),
            ("condition", conditionExpression),
            ("names", expressionAttributeNames.isEmpty ? nil : RequestRender.nameMap(expressionAttributeNames)),
            ("values", expressionAttributeValues.isEmpty ? nil : RequestRender.valueMap(expressionAttributeValues)),
        ])
    }
}

extension UpdateInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("UpdateItem \(tableName)", [
            ("key", RequestRender.valueMap(key)),
            ("update", updateExpression),
            ("condition", conditionExpression),
            ("names", expressionAttributeNames.isEmpty ? nil : RequestRender.nameMap(expressionAttributeNames)),
            ("values", expressionAttributeValues.isEmpty ? nil : RequestRender.valueMap(expressionAttributeValues)),
        ])
    }
}

extension UpdateReturning: RenderableRequest {
    public var renderedRequest: String {
        renderLines(input.renderedRequest, [
            ("returnValues", "\(returnValues)"),
        ])
    }
}

extension DeleteItemInput: RenderableRequest {
    public var renderedRequest: String {
        renderLines("DeleteItem \(tableName)", [
            ("key", RequestRender.valueMap(key)),
            ("condition", conditionExpression),
            ("names", expressionAttributeNames.isEmpty ? nil : RequestRender.nameMap(expressionAttributeNames)),
            ("values", expressionAttributeValues.isEmpty ? nil : RequestRender.valueMap(expressionAttributeValues)),
        ])
    }
}

extension BatchGetInput: RenderableRequest {
    public var renderedRequest: String {
        let keysRendered = keys.isEmpty ? nil
            : keys.map { RequestRender.valueMap($0) }.joined(separator: "\n        ")
        return renderLines("BatchGet \(tableName)", [
            ("keys", keysRendered),
            ("project", projectionAttributes.map { $0.joined(separator: ", ") }),
            ("consistentRead", consistentRead ? "true" : nil),
        ])
    }
}

extension BatchWriteInput: RenderableRequest {
    public var renderedRequest: String {
        let puts = putItems.isEmpty ? nil
            : putItems.map { RequestRender.item($0) }.joined(separator: "\n        ")
        let deletes = deleteKeys.isEmpty ? nil
            : deleteKeys.map { RequestRender.valueMap($0) }.joined(separator: "\n           ")
        return renderLines("BatchWrite \(tableName)", [
            ("puts", puts),
            ("deletes", deletes),
        ])
    }
}

extension TransactWriteInput: RenderableRequest {
    public var renderedRequest: String {
        var lines = ["TransactWrite"]
        for (index, item) in items.enumerated() {
            lines.append(item.renderedRequest(index: index))
        }
        return lines.joined(separator: "\n")
    }
}

extension TransactGetInput: RenderableRequest {
    public var renderedRequest: String {
        var items: [TransactGetItem] = []
        repeat items.append((each legs).transactGetItem)

        var lines = ["TransactGet"]
        for (index, item) in items.enumerated() {
            lines.append(item.renderedRequest(index: index))
        }
        return lines.joined(separator: "\n")
    }
}

private extension TransactWriteItem {
    func renderedRequest(index: Int) -> String {
        switch kind {
        case let .put(item, condition):
            return renderTransactionLines(
                "[\(index)] Put \(tableName)",
                [
                    ("item", RequestRender.item(item)),
                    ("condition", condition?.expression),
                    ("names", condition?.renderedNames),
                    ("values", condition?.renderedValues),
                ]
            )

        case let .update(key, updateExpression, condition, names, values):
            return renderTransactionLines(
                "[\(index)] Update \(tableName)",
                [
                    ("key", RequestRender.valueMap(key)),
                    ("update", updateExpression),
                    ("condition", condition?.expression),
                    ("names", !names.isEmpty ? RequestRender.nameMap(names) : nil),
                    ("values", !values.isEmpty ? RequestRender.valueMap(values) : nil),
                ]
            )

        case let .delete(key, condition):
            return renderTransactionLines(
                "[\(index)] Delete \(tableName)",
                [
                    ("key", RequestRender.valueMap(key)),
                    ("condition", condition?.expression),
                    ("names", condition?.renderedNames),
                    ("values", condition?.renderedValues),
                ]
            )

        case let .conditionCheck(key, condition):
            return renderTransactionLines(
                "[\(index)] ConditionCheck \(tableName)",
                [
                    ("key", RequestRender.valueMap(key)),
                    ("condition", condition.expression),
                    ("names", condition.renderedNames),
                    ("values", condition.renderedValues),
                ]
            )
        }
    }
}

private extension TransactGetItem {
    func renderedRequest(index: Int) -> String {
        renderTransactionLines(
            "[\(index)] Get \(tableName)",
            [
                ("key", RequestRender.valueMap(key)),
                ("project", projectionAttributes.map { $0.joined(separator: ", ") }),
            ]
        )
    }
}

private extension TransactWriteItem.Condition {
    var renderedNames: String? {
        attributeNames.isEmpty ? nil : RequestRender.nameMap(attributeNames)
    }

    var renderedValues: String? {
        attributeValues.isEmpty ? nil : RequestRender.valueMap(attributeValues)
    }
}

private func renderTransactionLines(_ header: String, _ fields: [(String, String?)]) -> String {
    var output = "  " + header
    for (label, value) in fields {
        guard let value, !value.isEmpty else { continue }
        output += "\n    \(label): \(value)"
    }
    return output
}
