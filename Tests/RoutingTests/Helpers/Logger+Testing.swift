//
//  Logger+Testing.swift
//
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

import Logging

extension Logger {
    /// Silent logger for router dispatch in tests.
    static let testing = Logger(
        label: "RoutingTests",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
}
