//
//  Headers.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

/// A case-insensitive HTTP header lookup.
///
/// Header names are normalized to lowercase on insertion, and lookup names are
/// normalized to lowercase before searching, so `headers["Host"]`,
/// `headers["host"]`, and `headers["HOST"]` all hit the same slot. This frees
/// callers from having to remember which casing the upstream sender used.
///
/// `Headers` mirrors the shape of `QueryParameters` and `PathParameters` so
/// handlers see a consistent typed-accessor pattern across all request slots.
public struct Headers: Sendable {
    private var values: [String: String] = [:]

    public init() {}

    public init(values: [String: String]) {
        self.values = Dictionary(
            values.lazy.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Get a header value by name. Lookup is case-insensitive.
    public func get(_ name: String) -> String? {
        self.values[name.lowercased()]
    }

    /// Get a header value by name. Lookup is case-insensitive.
    public subscript(name: String) -> String? {
        self.get(name)
    }

    /// Get a header value by name, throwing if missing.
    public func require(_ name: String) throws -> String {
        guard let value = get(name) else {
            throw HeaderError.missing(name)
        }
        return value
    }

    /// All header names that were present, normalized to lowercase.
    public var allNames: Set<String> {
        Set(self.values.keys)
    }
}
