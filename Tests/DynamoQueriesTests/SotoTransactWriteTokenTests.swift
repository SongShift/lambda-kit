import DynamoQueries
import DynamoQueriesSoto
import Foundation
import NIOCore
import NIOHTTP1
import SotoCore
import SotoDynamoDB
import Testing

/// Answers every request with one canned response and keeps the bodies sent.
private actor CapturingHTTPClient: AWSHTTPClient {
    private(set) var bodies: [[String: Any]] = []
    private let status: HTTPResponseStatus
    private let responseBody: String

    init(status: HTTPResponseStatus = .ok, responseBody: String = "{}") {
        self.status = status
        self.responseBody = responseBody
    }

    func execute(
        request: AWSHTTPRequest,
        timeout _: TimeAmount,
        logger _: Logger
    ) async throws -> AWSHTTPResponse {
        let buffer = try await request.body.collect(upTo: 1_000_000)
        let json = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))
        self.bodies.append(json as? [String: Any] ?? [:])
        return AWSHTTPResponse(
            status: self.status,
            headers: ["content-type": "application/x-amz-json-1.0"],
            body: .init(string: self.responseBody)
        )
    }

    var tokens: [String?] {
        self.bodies.map { $0["ClientRequestToken"] as? String }
    }
}

@Suite("Soto transact write idempotency token")
struct SotoTransactWriteTokenTests {
    private let transaction = TransactWriteInput {
        PhotoScan.update(partitionKey: "scan-abc") { column in
            column.status.set(to: "processing")
        }
    }

    private func withClient(
        _ http: CapturingHTTPClient,
        _ body: (SotoDynamoClient) async throws -> Void
    ) async throws {
        let aws = AWSClient(
            credentialProvider: .static(accessKeyId: "key", secretAccessKey: "secret"),
            retryPolicy: .noRetry,
            httpClient: http
        )
        let client = SotoDynamoClient(database: DynamoDB(client: aws, region: .useast2))
        do {
            try await body(client)
        } catch {
            try await aws.shutdown()
            throw error
        }
        try await aws.shutdown()
    }

    @Test("A token given to execute is sent unchanged on every attempt")
    func sendsGivenToken() async throws {
        let http = CapturingHTTPClient()
        try await self.withClient(http) { client in
            try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
            try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
        }
        #expect(await http.tokens == ["attempt-token", "attempt-token"])
    }

    @Test("Without a token each call still sends a fresh one")
    func generatesTokenPerCall() async throws {
        let http = CapturingHTTPClient()
        try await self.withClient(http) { client in
            try await self.transaction.execute(using: client)
            try await client.transactWrite(self.transaction.items, logger: .dynamoQueriesDisabled)
        }
        let tokens = await http.tokens.compactMap(\.self)
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
            try await self.withClient(http) { client in
                try await self.transaction.execute(using: client, idempotencyToken: "attempt-token")
            }
        }
        #expect(failure?.reason == .unknown(code: "IdempotentParameterMismatchException"))
        #expect(failure?.isRetryable == false)
    }
}
