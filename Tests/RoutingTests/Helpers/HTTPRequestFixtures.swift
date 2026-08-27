//
//  HTTPRequestFixtures.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import AWSLambdaEvents
import Foundation
import Routing

enum HTTPRequestFixtures {
    /// Builds a request through JSON because `APIGatewayV2Request` has no public initializer.
    /// Shaped like a `/{proxy+}` HTTP API (payload 2.0) event.
    static func makeRequest(
        method: String = "POST",
        path: String,
        headers: [String: String] = [:],
        body: String? = nil
    ) throws -> HTTPRequest {
        var payload: [String: Any] = [
            "version": "2.0",
            "routeKey": "ANY /{proxy+}",
            "rawPath": path,
            "rawQueryString": "",
            "headers": headers,
            "pathParameters": ["proxy": path.hasPrefix("/") ? String(path.dropFirst()) : path],
            "requestContext": [
                "accountId": "123456789012",
                "apiId": "api-id",
                "domainName": "example.com",
                "domainPrefix": "example",
                "http": [
                    "method": method,
                    "path": path,
                    "protocol": "HTTP/1.1",
                    "sourceIp": "127.0.0.1",
                    "userAgent": "test",
                ],
                "requestId": "request-id",
                "routeKey": "ANY /{proxy+}",
                "stage": "$default",
                "time": "12/Mar/2026:19:03:58 +0000",
                "timeEpoch": 1_583_348_638_390,
            ],
            "isBase64Encoded": false,
        ]
        if let body {
            payload["body"] = body
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try JSONDecoder().decode(APIGatewayV2Request.self, from: data)
        return HTTPRequest(event: event)
    }
}
