//
//  QueryParameterError.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

/// Thrown by `QueryParameters.require` when a parameter is absent or not convertible.
/// `Router.handle` maps it to `400 Bad Request`.
public enum QueryParameterError: Error {
    case missing(String)
    case invalidType(name: String, value: String, expectedType: String)

    public var message: String {
        switch self {
        case let .missing(name):
            "Missing required query parameter: \(name)"
        case let .invalidType(name, value, expectedType):
            "Query parameter '\(name)' value '\(value)' is not a valid \(expectedType)"
        }
    }
}
