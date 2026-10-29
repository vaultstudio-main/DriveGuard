//
//  EventLog.swift
//  DriveGuard
//

import Foundation
import Observation
import os

/// The activity log. Kept in memory for the window, and saved to a small file on this Mac so it
/// survives a quit, a crash or a restart (the file never leaves the Mac; Clear empties it).
@MainActor
@Observable
final class EventLog {
    enum Level: String, Codable {
        case info, warning, error
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String

        init(date: Date = Date(), level: Level, message: String) {
            self.date = date
            self.level = level
            self.message = message
        }
    }

    /// One line of the saved file.
    private struct Line: Codable {
        let d: Date
        let l: Level
        let m: String
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let logger = Logger(subsystem: "vault.DriveGuard", category: "events")
    @ObservationIgnored private let maxEntries = 500
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("DriveGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("activity.log")
        load()
    }

    /// Where the saved log lives, for people who want to look at it outside the app.
    var savedLogPath: String { fileURL.path }

    func add(_ message: String, level: Level = .info) {
        let entry = Entry(level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        append(entry)
        // .notice (not .info) so macOS keeps these lines too.
        switch level {
        case .info: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
        try? Data().write(to: fileURL)
    }

    // MARK: Saved file

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let loaded = lines.compactMap { line -> Entry? in
            guard let parsed = try? decoder.decode(Line.self, from: Data(line.utf8)) else { return nil }
            return Entry(date: parsed.d, level: parsed.l, message: parsed.m)
        }
        entries = Array(loaded.suffix(maxEntries))
        // Keep the file from growing for ever: rewrite it with just what is kept.
        if lines.count > maxEntries * 2 { rewrite() }
    }

    private func append(_ entry: Entry) {
        guard var data = try? encoder.encode(Line(d: entry.date, l: entry.level, m: entry.message)) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rewrite() {
        var data = Data()
        for entry in entries {
            if let line = try? encoder.encode(Line(d: entry.date, l: entry.level, m: entry.message)) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? data.write(to: fileURL)
    }
}
