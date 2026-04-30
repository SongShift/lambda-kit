//
//  PathParameters.swift
//
//  Created by Ben Rosen on 4/6/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

public struct PathParameters: Sendable {
    private var values: [String: String] = [:]

    public init() {}

    init(values: [String: String]) {
        self.values = values
    }

    /// Get a path parameter by name as a String.
    public func get(_ name: String) -> String? {
        self.values[name]
    }

    /// Get a path parameter by name, converting to the specified type.
    public func get<T: LosslessStringConvertible>(_ name: String, as type: T.Type) -> T? {
        self.get(name).flatMap(T.init)
    }

    /// Get a path parameter by name, throwing if missing.
    public func require(_ name: String) throws -> String {
        guard let value = get(name) else {
            throw PathParameterError.missing(name)
        }
        return value
    }

    /// Get a path parameter by name and type, throwing if missing or unconvertible.
    public func require<T: LosslessStringConvertible>(_ name: String, as type: T.Type) throws -> T {
        guard let raw = get(name) else {
            throw PathParameterError.missing(name)
        }
        guard let value = T(raw) else {
            throw PathParameterError.invalidType(name: name, value: raw, expectedType: "\(T.self)")
        }
        return value
    }

    public var allNames: Set<String> {
        Set(self.values.keys)
    }

    mutating func set(_ name: String, to value: String) {
        self.values[name] = value
    }
}

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
