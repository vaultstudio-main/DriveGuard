//
//  TimeMachine.swift
//  DriveGuard
//

import Foundation

nonisolated enum TimeMachine {
    enum BackupState: Sendable {
        case idle
        case running
        /// We could not tell. Callers must treat this as "not safe to unmount".
        case unknown(String)
    }

    struct Destination: Equatable, Sendable {
        let id: String
        let name: String
        let mountPoint: String?
    }

    /// Configured Time Machine destinations from `tmutil destinationinfo -X`.
    static func destinations() async -> [Destination] {
        guard
            let data = await Tool.run("/usr/bin/tmutil", ["destinationinfo", "-X"]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let list = (plist as? [String: Any])?["Destinations"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let id = entry["ID"] as? String else { return nil }
            return Destination(id: id, name: entry["Name"] as? String ?? "Time Machine",
                               mountPoint: entry["MountPoint"] as? String)
        }
    }

    /// Runs `tmutil status -X` and reports whether a backup is in progress.
    static func backupState() async -> BackupState {
        await Task.detached { queryTmutil() }.value
    }

    private static func queryTmutil() -> BackupState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["status", "-X"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unknown("could not launch tmutil: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .unknown("tmutil exited with status \(process.terminationStatus)")
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let running = dict["Running"] as? Bool
        else {
            return .unknown("unexpected tmutil output")
        }
        return running ? .running : .idle
    }
}
