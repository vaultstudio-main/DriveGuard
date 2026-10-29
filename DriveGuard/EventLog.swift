//
//  EventLog.swift
//  DriveGuard
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class EventLog {
    enum Level {
        case info, warning, error
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []

    private let logger = Logger(subsystem: "vault.DriveGuard", category: "events")
    private let maxEntries = 500

    func add(_ message: String, level: Level = .info) {
        entries.append(Entry(level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
    }
}
