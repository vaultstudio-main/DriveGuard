//
//  Tools.swift
//  DriveGuard
//

import Foundation

/// Runs a command-line tool off the main thread and returns its stdout, or nil on any failure
/// (launch error, non-zero exit when `requireSuccess`, or timeout).
nonisolated enum Tool {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10,
                    requireSuccess: Bool = true) async -> Data? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }

            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            if requireSuccess && process.terminationStatus != 0 { return nil }
            return data
        }.value
    }
}

nonisolated extension Tool {
    /// Runs a tool, optionally feeding it one line on standard input (for passwords: never put those on the
    /// command line), and returns its exit status and combined output. nil if it could not be started.
    static func runCapturing(_ path: String, _ arguments: [String], input: String? = nil,
                             timeout: TimeInterval = 60) async -> (status: Int32, output: String)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            do { try process.run() } catch { return nil }

            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
                try? stdin.fileHandleForWriting.close()
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// A file held open on a volume, as reported by lsof.
nonisolated struct OpenFile: Sendable {
    let pid: String
    let command: String
    let access: String // r, w or u (read/write)
    let path: String

    var isWriter: Bool { access == "w" || access == "u" }

    /// Index and housekeeping files macOS keeps open on every volume; they say nothing about user activity.
    var isBackgroundNoise: Bool {
        let noisyPaths = ["/.Spotlight-V100", "/.fseventsd", "/.TemporaryItems",
                          "/.DocumentRevisions-V100", "/.Trashes", "/.MobileBackups"]
        if noisyPaths.contains(where: { path.contains($0) }) { return true }
        return ["mds", "mds_stores", "mdworker_shared", "fseventsd"].contains(command)
    }
}

nonisolated enum OpenFiles {
    /// Files open on the volume mounted at `mountPath`; nil if lsof could not answer.
    /// Run as a normal user, lsof can only see processes you own, so this is a best-effort hint
    /// and never a substitute for the unmount itself being refused.
    static func list(onVolume mountPath: String) async -> [OpenFile]? {
        guard let data = await Tool.run("/usr/sbin/lsof", ["-F", "pcan", "--", mountPath],
                                        timeout: 15, requireSuccess: false) else { return nil }
        var files: [OpenFile] = []
        var pid = "", command = "", access = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = value
            case "c": command = value
            case "a": access = value
            case "n": files.append(OpenFile(pid: pid, command: command, access: access, path: value))
            default: break
            }
        }
        return files
    }

    /// "Preview (pid 412), Finder (pid 301)": a short, de-duplicated description for the log.
    static func summary(_ files: [OpenFile], limit: Int = 5) -> String {
        var seen = Set<String>()
        let names = files.compactMap { file -> String? in
            let label = "\(file.command) (pid \(file.pid))"
            return seen.insert(label).inserted ? label : nil
        }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? shown + ", and \(names.count - limit) more" : shown
    }
}
