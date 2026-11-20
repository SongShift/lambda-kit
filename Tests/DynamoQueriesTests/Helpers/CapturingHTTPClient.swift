import DynamoQueriesSoto
import Foundation
import NIOCore
import NIOHTTP1
import SotoCore
import SotoDynamoDB

/// Answers every request with one canned response and keeps the bodies sent,
/// so a test can assert on what `SotoDynamoClient` actually puts on the wire.
actor CapturingHTTPClient: AWSHTTPClient {
    /// The raw JSON body of each request, in call order.
    private(set) var payloads: [Data] = []
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
        self.payloads.append(Data(buffer.readableBytesView))
        return AWSHTTPResponse(
            status: self.status,
            headers: ["content-type": "application/x-amz-json-1.0"],
            body: .init(string: self.responseBody)
        )
    }

    /// Every request body decoded as `type`.
    func requests<Body: Decodable>(as type: Body.Type) throws -> [Body] {
        try self.payloads.map { try JSONDecoder().decode(type, from: $0) }
    }
}

/// Runs `body` with a `SotoDynamoClient` whose requests all go to `http`.
func withSotoClient(
    sendingTo http: CapturingHTTPClient,
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
