import Foundation
import SotoDynamoDB
import Testing

// MARK: - Resolved expression
//
// DynamoQueries allocates anonymous placeholders (`#n0`, `:v0`, ...) while
// hand-written Soto code uses readable names (`:userId`, `:trueValue`). To
// compare them, we substitute every placeholder with its underlying attribute
// name / attribute value and compare the resulting strings byte-for-byte. The
// Soto reference fixtures in this test target are written using the same
// parenthesization the DynamoQueries `ExpressionCompiler` emits. Once
// placeholders are resolved, the two strings are identical.

struct ResolvedExpression: Equatable, CustomStringConvertible {
    let expanded: String
    var description: String { expanded }
}

func resolve(
    expression: String?,
    names: [String: String]?,
    values: [String: DynamoDB.AttributeValue]?
) -> ResolvedExpression? {
    guard let expression else { return nil }
    var expanded = expression

    // Substitute longest placeholder names first so `:vNN` doesn't get
    // partially eaten by `:vN`.
    if let names {
        for (placeholder, attribute) in names.sorted(by: { $0.key.count > $1.key.count }) {
            expanded = expanded.replacingOccurrences(of: placeholder, with: attribute)
        }
    }
    if let values {
        for (placeholder, value) in values.sorted(by: { $0.key.count > $1.key.count }) {
            expanded = expanded.replacingOccurrences(of: placeholder, with: dump(value))
        }
    }
    return ResolvedExpression(expanded: expanded)
}

private func dump(_ value: DynamoDB.AttributeValue) -> String {
    switch value {
    case .s(let s): return "S(\(s))"
    case .n(let n): return "N(\(n))"
    case .bool(let b): return "BOOL(\(b))"
    case .b(let b): return "B(\(b))"
    case .null(let n): return "NULL(\(n))"
    case .ss(let xs): return "SS(\(xs.sorted()))"
    case .ns(let xs): return "NS(\(xs.sorted()))"
    case .bs(let xs): return "BS(\(xs.map(String.init(describing:)).sorted()))"
    case .l(let xs): return "L([\(xs.map(dump).joined(separator: ","))])"
    case .m(let m):
        let body = m.sorted { $0.key < $1.key }
            .map { "\($0.key):\(dump($0.value))" }
            .joined(separator: ",")
        return "M({\(body)})"
    }
}

// MARK: - QueryInput equivalence

func expectEquivalent(
    _ lhs: DynamoDB.QueryInput,
    _ rhs: DynamoDB.QueryInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(lhs.indexName == rhs.indexName, "indexName", sourceLocation: sourceLocation)
    #expect(lhs.limit == rhs.limit, "limit", sourceLocation: sourceLocation)
    #expect(lhs.scanIndexForward == rhs.scanIndexForward, "scanIndexForward", sourceLocation: sourceLocation)
    #expect(lhs.exclusiveStartKey == rhs.exclusiveStartKey, "exclusiveStartKey", sourceLocation: sourceLocation)
    #expect(
        resolve(expression: lhs.keyConditionExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.keyConditionExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "keyConditionExpression",
        sourceLocation: sourceLocation
    )
    #expect(
        resolve(expression: lhs.filterExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.filterExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "filterExpression",
        sourceLocation: sourceLocation
    )
}

// MARK: - ScanInput equivalence

func expectEquivalent(
    _ lhs: DynamoDB.ScanInput,
    _ rhs: DynamoDB.ScanInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(lhs.indexName == rhs.indexName, "indexName", sourceLocation: sourceLocation)
    #expect(lhs.limit == rhs.limit, "limit", sourceLocation: sourceLocation)
    #expect(lhs.exclusiveStartKey == rhs.exclusiveStartKey, "exclusiveStartKey", sourceLocation: sourceLocation)
    #expect(
        resolve(expression: lhs.filterExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.filterExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "filterExpression",
        sourceLocation: sourceLocation
    )
}

// MARK: - GetItemInput equivalence

func expectEquivalent(
    _ lhs: DynamoDB.GetItemInput,
    _ rhs: DynamoDB.GetItemInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(lhs.key == rhs.key, "key", sourceLocation: sourceLocation)
}

// MARK: - UpdateItemInput equivalence

func expectEquivalent(
    _ lhs: DynamoDB.UpdateItemInput,
    _ rhs: DynamoDB.UpdateItemInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(lhs.key == rhs.key, "key", sourceLocation: sourceLocation)
    #expect(
        resolve(expression: lhs.updateExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.updateExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "updateExpression",
        sourceLocation: sourceLocation
    )
    #expect(
        resolve(expression: lhs.conditionExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.conditionExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "conditionExpression",
        sourceLocation: sourceLocation
    )
}

// MARK: - DeleteItemInput equivalence

func expectEquivalent(
    _ lhs: DynamoDB.DeleteItemInput,
    _ rhs: DynamoDB.DeleteItemInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(lhs.key == rhs.key, "key", sourceLocation: sourceLocation)
    #expect(
        resolve(expression: lhs.conditionExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.conditionExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "conditionExpression",
        sourceLocation: sourceLocation
    )
}

// MARK: - PutItemInput equivalence (item body intentionally not compared)
//
// The PutItem fixtures here exercise condition expressions only: the item
// payload itself is encoded by the Soto adapter through `JSONEncoder` /
// `JSONSerialization` (see `DynamoEncoder` in DynamoQueriesSoto), and the
// hand-written reference uses Soto's own `DynamoDBEncoder`. The two encoders
// disagree on `Double` formatting (`1.0` vs `1`) and on attribute ordering, so
// asserting on the encoded item is mostly testing JSON round-trip noise rather
// than DynamoQueries' compiler. Tests that need to exercise a specific item
// shape can compare `lhs.item == rhs.item` directly.

func expectEquivalentMetadata(
    _ lhs: DynamoDB.PutItemInput,
    _ rhs: DynamoDB.PutItemInput,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(lhs.tableName == rhs.tableName, "tableName", sourceLocation: sourceLocation)
    #expect(
        resolve(expression: lhs.conditionExpression, names: lhs.expressionAttributeNames, values: lhs.expressionAttributeValues)
            == resolve(expression: rhs.conditionExpression, names: rhs.expressionAttributeNames, values: rhs.expressionAttributeValues),
        "conditionExpression",
        sourceLocation: sourceLocation
    )
}
