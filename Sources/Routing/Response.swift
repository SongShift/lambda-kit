//
//  Response.swift
//
//  Created by Ben Rosen on 4/6/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Foundation
import HTTPTypes

/// Wire-ready response. Produced by `Router.handle`, consumed by the edge.
public struct Response: Sendable {
    public var statusCode: HTTPResponse.Status
    public var headers: [String: String]
    public var body: String?

    public init(
        statusCode: HTTPResponse.Status,
        headers: [String: String] = [:],
        body: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// JSON error response with shape `{"error":"<message>"}`.
    public static func error(
        statusCode: HTTPResponse.Status,
        message: String,
        headers: [String: String] = [:]
    ) -> Response {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return Response(
            statusCode: statusCode,
            headers: headers,
            body: "{\"error\":\"\(message)\"}"
        )
    }
}

/// Handler-authored response. Built via the static factories; JSON bodies
/// are encoded by `Router.handle` via `encoded()`.
public struct RouteResponse: Sendable {
    public var statusCode: HTTPResponse.Status
    public var headers: [String: String]
    public var body: Body

    public enum Body: Sendable {
        case empty
        case string(String)
        case json(any Encodable & Sendable)
    }

    private init(
        statusCode: HTTPResponse.Status,
        headers: [String: String],
        body: Body
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// JSON response. Encoding is deferred to `Router.handle`.
    public static func json(
        _ body: some Encodable & Sendable,
        statusCode: HTTPResponse.Status,
        headers: [String: String] = [:]
    ) -> RouteResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return RouteResponse(statusCode: statusCode, headers: headers, body: .json(body))
    }

    /// Raw, already-encoded string body.
    public static func string(
        _ body: String,
        statusCode: HTTPResponse.Status,
        headers: [String: String] = [:]
    ) -> RouteResponse {
        RouteResponse(statusCode: statusCode, headers: headers, body: .string(body))
    }

    /// Body-less response.
    public static func empty(
        statusCode: HTTPResponse.Status,
        headers: [String: String] = [:]
    ) -> RouteResponse {
        RouteResponse(statusCode: statusCode, headers: headers, body: .empty)
    }

    /// JSON error response with shape `{"error":"<message>"}`.
    public static func error(
        statusCode: HTTPResponse.Status,
        message: String,
        headers: [String: String] = [:]
    ) -> RouteResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return RouteResponse(
            statusCode: statusCode,
            headers: headers,
            body: .string("{\"error\":\"\(message)\"}")
        )
    }

    /// Encode this response into a wire-ready `Response`. Throws on JSON
    /// encoding failure.
    public func encoded(encoder: JSONEncoder = JSONEncoder()) throws -> Response {
        let bodyString: String?
        switch self.body {
        case .empty:
            bodyString = nil
        case let .string(s):
            bodyString = s
        case let .json(value):
            bodyString = try String(decoding: encoder.encode(value), as: UTF8.self)
        }
        return Response(
            statusCode: self.statusCode,
            headers: self.headers,
            body: bodyString
        )
    }
}
