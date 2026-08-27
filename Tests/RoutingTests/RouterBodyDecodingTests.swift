//
//  RouterBodyDecodingTests.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Logging
import Routing
import Testing

@Suite("Router+bodyDecoding")
struct RouterBodyDecodingTests {
    struct Input: Decodable, Sendable {
        let id: String
    }

    let router: HTTPRouter

    init() {
        let builder = HTTPRouterBuilder()
        builder.post("/echo", body: Input.self) { _, input, _ in
            .string(input.id, statusCode: .ok)
        }
        self.router = builder.build()
    }

    @Test("Valid body is decoded and passed to the handler")
    func validBody() async throws {
        let response = await router.handle(
            try HTTPRequestFixtures.makeRequest(path: "/echo", body: #"{"id":"abc"}"#),
            logger: .testing
        )
        #expect(response.statusCode == .ok)
        #expect(response.body == "abc")
    }

    @Test(
        "Undecodable body returns 400",
        arguments: [nil, "", "not json", #"{"wrong":1}"#, #"{"id":1}"#] as [String?]
    )
    func undecodableBody(body: String?) async throws {
        let response = await router.handle(
            try HTTPRequestFixtures.makeRequest(path: "/echo", body: body),
            logger: .testing
        )
        #expect(response.statusCode == .badRequest)
        #expect(response.body?.contains("The request body could not be decoded.") == true)
    }
}
