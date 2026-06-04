import DynamoQueries
import Foundation
import Testing

// Covers `@ExpressionValue(as:)` end to end: the macro generating a
// `RepresentedAttribute`, and update actions encoding through the
// consumer-declared representation (`GearSlotMapEncoder` in
// `Models/TrailLog.swift`).

@Suite("Represented columns")
struct RepresentedColumnTests {

    @Test("set(to:) encodes an Int-keyed Codable dictionary as a native map")
    func setEncodesThroughRepresentation() throws {
        let input = try GearLocker.update(partitionKey: "hiker-1") { column in
            try column.slots.set(to: [1: GearSlot(label: "Tent", weight: 12.5)])
        }

        #expect(input.updateExpression == "SET #n0 = :v0")
        #expect(input.expressionAttributeNames == ["#n0": "slots"])
        #expect(input.expressionAttributeValues == [
            ":v0": .map([
                "1": .map([
                    "label": .string("Tent"),
                    "weight": .number("12.5"),
                ]),
            ]),
        ])
    }

    @Test("represented and plain columns mix in one update builder")
    func mixedBuilder() throws {
        let input = try GearLocker.update(partitionKey: "hiker-1") { column in
            try column.slots.setIfNotExists([:])
            column.capacity.add(1)
        } where: { column in
            column.slots.exists
        }

        #expect(input.updateExpression == "SET #n0 = if_not_exists(#n0, :v0) ADD #n1 :v1")
        #expect(input.conditionExpression == "attribute_exists(#n2)")
        #expect(input.expressionAttributeNames == [
            "#n0": "slots", "#n1": "capacity", "#n2": "slots",
        ])
        #expect(input.expressionAttributeValues == [":v0": .map([:]), ":v1": .number("1")])
    }

    @Test("remove() needs no value and no try")
    func removeIsNonThrowing() {
        let input = GearLocker.update(partitionKey: "hiker-1") { column in
            column.slots.remove()
        }
        #expect(input.updateExpression == "REMOVE #n0")
    }
}
