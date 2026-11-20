import DynamoQueries
import DynamoQueriesSoto
import Foundation
import NIOHTTP1
import SotoDynamoDB
import Testing

private struct TransactWriteBody: Decodable, Sendable {
    let clientRequestToken: String?

    enum CodingKeys: String, CodingKey {
        case clientRequestToken = "ClientRequestToken"
    }
}

extension CapturingHTTPClient {
    fileprivate var tokens: [String?] {
        get throws {
            try self.requests(as: TransactWriteBody.self).map(\.clientRequestToken)
        }
    }
}

@Suite("Soto transact write idempotency token")
struct SotoTransactWriteTokenTests {
    private let transaction = TransactWriteInput {
        PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
    }

    @Test("A token given to execute is sent unchanged on every attempt")
    func sendsGivenToken() async throws {
        let http = CapturingHTTPClient()
        try await withSotoClient(sendingTo: http) { client in
            try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
            try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
        }
        #expect(try await http.tokens == ["attempt-token", "attempt-token"])
    }

    @Test("Without a token each call still sends a fresh one")
    func generatesTokenPerCall() async throws {
        let http = CapturingHTTPClient()
        try await withSotoClient(sendingTo: http) { client in
            try await self.transaction.execute(using: client)
            try await client.transactWrite(self.transaction.items, logger: .dynamoQueriesDisabled)
        }
        let tokens = try await http.tokens.compactMap(\.self)
        #expect(tokens.count == 2)
        #expect(Set(tokens).count == 2)
        #expect(tokens.allSatisfy { (1 ... 36).contains($0.count) })
    }

    @Test("A token reused with different items fails without being retryable")
    func mismatchIsNotRetryable() async throws {
        let http = CapturingHTTPClient(
            status: .badRequest,
            responseBody: """
            {"__type":"com.amazonaws.dynamodb.v20120810#IdempotentParameterMismatchException",\
            "message":"Request parameters differ"}
            """
        )
        let failure = await #expect(throws: DynamoFailure.self) {
            try await withSotoClient(sendingTo: http) { client in
                try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
            }
        }
        #expect(failure?.reason == .unknown(code: "IdempotentParameterMismatchException"))
        #expect(failure?.isRetryable == false)
    }
}
