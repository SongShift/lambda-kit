//
//  PathParameterError.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

/// Thrown by `PathParameters.require` when a parameter is absent or not convertible.
/// `Router.handle` maps it to `400 Bad Request`.
public enum PathParameterError: Error {
    case missing(String)
    case invalidType(name: String, value: String, expectedType: String)

    public var message: String {
        switch self {
        case let .missing(name):
            "Missing required path parameter: \(name)"
        case let .invalidType(name, value, expectedType):
            "Path parameter '\(name)' value '\(value)' is not a valid \(expectedType)"
        }
    }
}
