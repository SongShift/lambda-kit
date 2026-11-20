//
//  ErrorResponseTests.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Foundation
import HTTPTypes
import Routing
import Testing

@Suite("ErrorResponseTests")
struct ErrorResponseTests {
    @Test(
        "An error body is valid JSON whatever the message holds",
        arguments: [
            "Not found",
            #"No hike with id "abc""#,
            #"keyNotFound(CodingKeys(stringValue: "id", intValue: nil))"#,
            #"C:\path\to\file"#,
            "first line\nsecond line",
            "https://example.com/a/b",
            "",
        ]
    )
    func bodyDecodes(message: String) throws {
        let wire = try RouteResponse
            .error(statusCode: .internalServerError, message: message)
            .encoded()
        let direct = Response.error(statusCode: .internalServerError, message: message)

        for body in [wire.body, direct.body] {
            let data = try #require(body?.data(using: .utf8))
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            #expect(decoded == ["error": message])
        }
    }

    @Test(
        "A message with nothing to escape keeps the body it had",
        arguments: ["Not found", "https://example.com/a/b"]
    )
    func plainMessageUnchanged(message: String) throws {
        let expected = "{\"error\":\"\(message)\"}"

        #expect(Response.error(statusCode: .notFound, message: message).body == expected)
        #expect(
            try RouteResponse.error(statusCode: .notFound, message: message).encoded().body
                == expected
        )
    }

    @Test("An error response is sent as JSON")
    func contentType() {
        let response = Response.error(statusCode: .notFound, message: "Not found")

        #expect(response.headers["Content-Type"] == "application/json")
    }
}
