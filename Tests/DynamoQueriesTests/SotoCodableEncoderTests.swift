import DynamoQueries
import DynamoQueriesSoto
import Foundation
import Testing

@Suite("SotoCodableEncoder")
struct SotoCodableEncoderTests {

    private struct Receipt: Codable {
        var label: String
        var amount: Int
        var issuedAt: Date
        var note: String?
    }

    @Test("encodes Codable aggregates with 1970-epoch dates")
    func encodesCodableAggregates() throws {
        let value = try SotoCodableEncoder.encode(
            Receipt(
                label: "permit",
                amount: 3,
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                note: nil
            )
        )

        #expect(value == .map([
            "label": .string("permit"),
            "amount": .number("3"),
            "issuedAt": .number("1700000000.0"),
        ]))
    }

    @Test("drives set(to:via:) without a hand-rolled representation")
    func setViaDefaultEncoder() throws {
        let input = try Permit.update(partitionKey: "permit-1") { column in
            try column.hold.set(
                to: PermitHold(heldUntil: 1030, holdId: "hold-1"),
                via: SotoCodableEncoder.self
            )
        }

        #expect(input.updateExpression == "SET #n0 = :v0")
        #expect(input.expressionAttributeNames == ["#n0": "hold"])
        #expect(input.expressionAttributeValues == [
            ":v0": .map(["heldUntil": .number("1030.0"), "holdId": .string("hold-1")]),
        ])
    }
}
