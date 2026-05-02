//
//  APIGatewayV2Response+Hummingbird.swift
//  LambdaKit
//

import AWSLambdaEvents
import HTTPTypes
import Hummingbird
import NIOCore

extension APIGatewayV2Response {
    func toHummingbirdResponse() -> Response {
        var headers = HTTPFields()
        if let responseHeaders = self.headers {
            for (name, value) in responseHeaders {
                if let fieldName = HTTPField.Name(name) {
                    headers.append(HTTPField(name: fieldName, value: value))
                }
            }
        }

        let body: ResponseBody
        if let bodyString = self.body {
            body = .init(byteBuffer: ByteBuffer(string: bodyString))
        } else {
            body = .init()
        }

        return Response(
            status: .init(code: Int(statusCode.code)),
            headers: headers,
            body: body
        )
    }
}
