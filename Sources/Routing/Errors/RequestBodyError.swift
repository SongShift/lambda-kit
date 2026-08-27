//
//  RequestBodyError.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

/// Thrown when a request body cannot be decoded into a handler's `Body` type.
/// `Router.handle` maps it to `400 Bad Request`.
public enum RequestBodyError: Error {
    case decodingFailed(any Error)

    public var message: String {
        switch self {
        case let .decodingFailed(error):
            "The request body could not be decoded."
        }
    }
}
