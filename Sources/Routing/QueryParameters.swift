//
//  QueryParameters.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

public struct QueryParameters: Sendable {
    private var values: [String: String] = [:]

    public init() {}

    public init(values: [String: String]) {
        self.values = values
    }

    /// Get a query parameter by name as a String.
    public func get(_ name: String) -> String? {
        self.values[name]
    }

    /// Get a query parameter by name, converting to the specified type.
    public func get<T: LosslessStringConvertible>(_ name: String, as type: T.Type) -> T? {
        self.get(name).flatMap(T.init)
    }

    /// Get a query parameter by name as a `RawRepresentable` (e.g. a `String`-backed enum).
    public func get<T: RawRepresentable>(
        _ name: String,
        as type: T.Type
    ) -> T? where T.RawValue == String {
        self.get(name).flatMap(T.init(rawValue:))
    }

    /// Get a query parameter by `CodingKey` as a String.
    public func get(_ key: some CodingKey) -> String? {
        self.get(key.stringValue)
    }

    /// Get a query parameter by `CodingKey`, converting to the specified type.
    public func get<T: LosslessStringConvertible>(_ key: some CodingKey, as type: T.Type) -> T? {
        self.get(key.stringValue, as: type)
    }

    /// Get a query parameter by `CodingKey` as a `RawRepresentable`.
    public func get<T: RawRepresentable>(
        _ key: some CodingKey,
        as type: T.Type
    ) -> T? where T.RawValue == String {
        self.get(key.stringValue, as: type)
    }

    /// Get a query parameter by name, throwing if missing.
    public func require(_ name: String) throws -> String {
        guard let value = get(name) else {
            throw QueryParameterError.missing(name)
        }
        return value
    }

    /// Get a query parameter by name and type, throwing if missing or unconvertible.
    public func require<T: LosslessStringConvertible>(
        _ name: String,
        as type: T.Type
    ) throws -> T {
        let raw = try self.require(name)
        guard let value = T(raw) else {
            throw QueryParameterError.invalidType(
                name: name,
                value: raw,
                expectedType: "\(T.self)"
            )
        }
        return value
    }

    /// Get a `RawRepresentable` query parameter by name, throwing if missing or unconvertible.
    public func require<T: RawRepresentable>(
        _ name: String,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        let raw = try self.require(name)
        guard let value = T(rawValue: raw) else {
            throw QueryParameterError.invalidType(
                name: name,
                value: raw,
                expectedType: "\(T.self)"
            )
        }
        return value
    }

    /// Get a query parameter by `CodingKey`, throwing if missing.
    public func require(_ key: some CodingKey) throws -> String {
        try self.require(key.stringValue)
    }

    /// Get a query parameter by `CodingKey` and type, throwing if missing or unconvertible.
    public func require<T: LosslessStringConvertible>(
        _ key: some CodingKey,
        as type: T.Type
    ) throws -> T {
        try self.require(key.stringValue, as: type)
    }

    /// Get a `RawRepresentable` query parameter by `CodingKey`, throwing if missing or
    /// unconvertible.
    public func require<T: RawRepresentable>(
        _ key: some CodingKey,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        try self.require(key.stringValue, as: type)
    }

    public var allNames: Set<String> {
        Set(self.values.keys)
    }
}
