import DynamoQueries
import DynamoQueriesSoto
import Foundation
import SotoDynamoDB
import Testing

// Round-trip tests for `DynamoValue` and the Soto bridge. The pagination
// token format depends on `DynamoValue: Codable` round-tripping every
// variant, and the Soto adapter depends on the symmetric
// `DynamoValue ↔ DynamoDB.AttributeValue` conversion.

@Suite("DynamoValue Codable")
struct DynamoValueCodableTests {

    @Test("Codable round-trip covers every variant")
    func codableRoundTripEveryVariant() throws {
        let cases: [DynamoValue] = [
            .string("hello"),
            .number("42"),
            .bool(true),
            .binary(Data([0xde, 0xad, 0xbe, 0xef])),
            .null,
            .list([.string("a"), .number("1"), .bool(false)]),
            .map(["nested": .string("yes"), "count": .number("3")]),
            .stringSet(["a", "b", "c"]),
            .numberSet(["1", "2", "3"]),
            .binarySet([Data([0x01]), Data([0x02])]),
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let restored = try JSONDecoder().decode(DynamoValue.self, from: data)
            #expect(restored == value)
        }
    }

    @Test("PaginationToken round-trips a binary primary key")
    func paginationTokenWithBinaryKey() throws {
        let original = PaginationToken(key: [
            "binId": .binary(Data([0xde, 0xad, 0xbe, 0xef])),
            "stringId": .string("abc"),
        ])
        let restored = try #require(PaginationToken(string: original.stringValue))
        #expect(restored == original)
    }
}

@Suite("DynamoValue ↔ Soto AttributeValue")
struct DynamoValueSotoBridgeTests {

    @Test("toSotoAttributeValue covers every variant")
    func toSotoAttributeValueCoversEveryVariant() {
        #expect(DynamoValue.string("x").toSotoAttributeValue() == .s("x"))
        #expect(DynamoValue.number("42").toSotoAttributeValue() == .n("42"))
        #expect(DynamoValue.bool(true).toSotoAttributeValue() == .bool(true))
        #expect(DynamoValue.null.toSotoAttributeValue() == .null(true))

        if case .b(let base64) = DynamoValue.binary(Data([0x01, 0x02])).toSotoAttributeValue() {
            #expect(base64.decoded() == [0x01, 0x02])
        } else {
            Issue.record("expected .b case")
        }

        if case .l(let elements) = DynamoValue.list([.string("a"), .number("1")]).toSotoAttributeValue() {
            #expect(elements == [.s("a"), .n("1")])
        } else {
            Issue.record("expected .l case")
        }

        if case .m(let entries) = DynamoValue.map(["k": .string("v")]).toSotoAttributeValue() {
            #expect(entries == ["k": .s("v")])
        } else {
            Issue.record("expected .m case")
        }

        if case .ss(let elements) = DynamoValue.stringSet(["a", "b"]).toSotoAttributeValue() {
            #expect(Set(elements) == ["a", "b"])
        } else {
            Issue.record("expected .ss case")
        }

        if case .ns(let elements) = DynamoValue.numberSet(["1", "2"]).toSotoAttributeValue() {
            #expect(Set(elements) == ["1", "2"])
        } else {
            Issue.record("expected .ns case")
        }

        if case .bs(let elements) = DynamoValue.binarySet([Data([0x01]), Data([0x02])]).toSotoAttributeValue() {
            let bytes = Set(elements.map { $0.decoded() ?? [] })
            #expect(bytes == [[0x01], [0x02]])
        } else {
            Issue.record("expected .bs case")
        }
    }
}

@Suite("DynamoEncodable conformances")
struct DynamoEncodableTests {

    @Test("Set<Int> encodes as numberSet of stringified ints")
    func setOfIntEncodesAsNumberSet() {
        let value = Set<Int>([1, 2, 3]).toDynamoValue()
        guard case .numberSet(let elements) = value else {
            Issue.record("expected .numberSet")
            return
        }
        #expect(elements == ["1", "2", "3"])
    }

    @Test("Set<Data> encodes as binarySet")
    func setOfDataEncodesAsBinarySet() {
        let value = Set<Data>([Data([0x01]), Data([0x02])]).toDynamoValue()
        guard case .binarySet(let elements) = value else {
            Issue.record("expected .binarySet")
            return
        }
        #expect(elements == [Data([0x01]), Data([0x02])])
    }

    @Test("Array<String> encodes as a list")
    func arrayOfStringEncodesAsList() {
        let value = ["a", "b", "c"].toDynamoValue()
        guard case .list(let elements) = value else {
            Issue.record("expected .list")
            return
        }
        #expect(elements == [.string("a"), .string("b"), .string("c")])
    }

    @Test("Dictionary<String, String> encodes as a map")
    func dictionaryEncodesAsMap() {
        let value: [String: String] = ["a": "1", "b": "2"]
        guard case .map(let entries) = value.toDynamoValue() else {
            Issue.record("expected .map")
            return
        }
        #expect(entries == ["a": .string("1"), "b": .string("2")])
    }

    @Test("Data encodes as binary")
    func dataEncodesAsBinary() {
        let value = Data([0xff, 0x00]).toDynamoValue()
        #expect(value == .binary(Data([0xff, 0x00])))
    }
}
