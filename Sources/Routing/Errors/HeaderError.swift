//
//  HeaderError.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

/// Thrown by `Headers.require` when a header is absent.
/// `Router.handle` maps it to `400 Bad Request`.
public enum HeaderError: Error {
    case missing(String)

    public var message: String {
        switch self {
        case let .missing(name):
            "Missing required header: \(name)"
        }
    }
}
