//
//  RequestTransformer.swift
//  LambdaKit
//

public protocol RequestTransformer: Sendable {
    func transform(_ request: inout MutableAPIGatewayV2Request) async
}
