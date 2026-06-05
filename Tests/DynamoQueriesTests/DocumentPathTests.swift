import DynamoQueries
import Foundation
import Testing

// Covers document paths (`nested(_:as:)` + per-component placeholder
// allocation) and call-site representations (`set(to:via:)`). The model is
// `Permit` in `Models/TrailLog.swift`, shaped like the canonical use case: a
// pessimistic lock stored as a nested map.

@Suite("Document paths")
struct DocumentPathTests {

    @Test("nested(_:as:) compiles each path component to its own placeholder")
    func nestedConditionCompiles() throws {
        let input = try Permit.update(partitionKey: "permit-1") { column in
            try column.hold.set(
                to: PermitHold(heldUntil: 1030, holdId: "hold-1"),
                via: PermitHoldEncoder.self
            )
        } where: { column in
            column.permitId.exists
            column.hold.doesNotExist
                || column.hold.nested(PermitHold.CodingKeys.heldUntil, as: Double.self) < 1000
                || column.hold.nested(PermitHold.CodingKeys.holdId, as: String.self) == "hold-1"
        }

        #expect(input.updateExpression == "SET #n0 = :v0")
        #expect(input.conditionExpression == "(attribute_exists(#n1)) AND (((attribute_not_exists(#n2)) OR (#n3.#n4 < :v1)) OR (#n5.#n6 = :v2))")
        #expect(input.expressionAttributeNames == [
            "#n0": "hold",
            "#n1": "permitId",
            "#n2": "hold",
            "#n3": "hold",
            "#n4": "heldUntil",
            "#n5": "hold",
            "#n6": "holdId",
        ])
        #expect(input.expressionAttributeValues == [
            ":v0": .map(["heldUntil": .number("1030.0"), "holdId": .string("hold-1")]),
            ":v1": .number("1000.0"),
            ":v2": .string("hold-1"),
        ])
    }

    @Test("nested(_:as:) accepts a string name and updates through the path")
    func nestedStringNameInUpdate() {
        let input = Permit.update(partitionKey: "permit-1") { column in
            column.hold.nested("holdId", as: String.self).set(to: "hold-2")
        }

        #expect(input.updateExpression == "SET #n0.#n1 = :v0")
        #expect(input.expressionAttributeNames == ["#n0": "hold", "#n1": "holdId"])
        #expect(input.expressionAttributeValues == [":v0": .string("hold-2")])
    }

    @Test("set(to:via:) encodes through the call-site representation")
    func setViaRepresentation() throws {
        // Non-optional column variant, constructed directly.
        let action = try Attribute<PermitHold>("hold").set(
            to: PermitHold(heldUntil: 5, holdId: "hold-3"),
            via: PermitHoldEncoder.self
        )

        #expect(action == .set(
            attributeName: "hold",
            value: .map(["heldUntil": .number("5.0"), "holdId": .string("hold-3")])
        ))
    }
}
