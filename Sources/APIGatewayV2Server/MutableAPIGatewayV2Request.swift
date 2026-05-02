//
//  MutableAPIGatewayV2Request.swift
//  LambdaKit
//

import AWSLambdaEvents
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

public struct MutableAPIGatewayV2Request: Encodable, Sendable {
    public var version: String = "2.0"
    public var routeKey: String = ""
    public var rawPath: String = ""
    public var rawQueryString: String = ""
    public var cookies: [String] = []
    public var headers: [String: String] = [:]
    public var queryStringParameters: [String: String] = [:]
    public var pathParameters: [String: String] = [:]
    public var stageVariables: [String: String] = [:]
    public var body: String?
    public var isBase64Encoded: Bool = false
    public var requestContext: Context

    public struct Context: Encodable, Sendable {
        public var accountId: String = "123456789012"
        public var apiId: String = "local"
        public var domainName: String = "localhost"
        public var domainPrefix: String = "local"
        public var stage: String = "$default"
        public var requestId: String = ""
        public var time: String = ""
        public var timeEpoch: UInt64 = 0
        public var http: HTTP
        public var authorizer: Authorizer?

        public struct HTTP: Encodable, Sendable {
            public var method: String = "GET"
            public var path: String = ""
            public var `protocol`: String = "HTTP/1.1"
            public var sourceIp: String = "127.0.0.1"
            public var userAgent: String = "HTTPGateway/1.0"
        }

        public struct Authorizer: Encodable, Sendable {
            public var jwt: JWT?
            public var lambda: [String: String]?

            public struct JWT: Encodable, Sendable {
                public var claims: [String: String]
                public var scopes: [String]?
            }
        }

        public init() {
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            self.time = formatter.string(from: now)
            self.timeEpoch = UInt64(now.timeIntervalSince1970 * 1000)
            self.requestId = UUID().uuidString
            self.http = HTTP()
        }
    }

    public init(from request: Request, body: ByteBuffer?, host: String) {
        self.requestContext = Context()
        
        self.rawPath = request.uri.path
        self.rawQueryString = request.uri.query ?? ""
        self.routeKey = "\(request.method.rawValue) \(self.rawPath)"

        if let query = request.uri.query {
            self.queryStringParameters = Self.parseQueryParameters(query)
        }

        for field in request.headers {
            let key = field.name.rawName.lowercased()
            if let existing = headers[key] {
                self.headers[key] = "\(existing),\(field.value)"
            } else {
                self.headers[key] = field.value
            }
        }

        if let cookieHeader = headers["cookie"] {
            self.cookies = cookieHeader.split(separator: ";").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
        }

        self.requestContext.http.method = request.method.rawValue
        self.requestContext.http.path = self.rawPath
        self.requestContext.http.userAgent = self.headers["user-agent"] ?? "HTTPGateway/1.0"

        let proxyPath = self.rawPath.hasPrefix("/") ? String(self.rawPath.dropFirst()) : self.rawPath
        self.pathParameters["proxy"] = proxyPath

        if let body, body.readableBytes > 0 {
            if let utf8 = body.getString(at: body.readerIndex, length: body.readableBytes) {
                self.body = utf8
                self.isBase64Encoded = false
            } else {
                self.body = Data(buffer: body).base64EncodedString()
                self.isBase64Encoded = true
            }
        }
    }

    public func build() throws -> APIGatewayV2Request {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(APIGatewayV2Request.self, from: data)
    }

    private static func parseQueryParameters(_ queryString: String) -> [String: String] {
        guard let components = URLComponents(string: "?\(queryString)"),
              let queryItems = components.queryItems else {
            return [:]
        }
        return queryItems.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }
}
