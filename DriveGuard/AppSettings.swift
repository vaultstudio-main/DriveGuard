//
//  AppSettings.swift
//  DriveGuard
//

import Foundation
import Observation

/// Events that can cause drives to be unmounted.
nonisolated enum Trigger: String, CaseIterable, Codable, Sendable {
    case screenLock, screenSaver, displaySleep, userSwitch, systemSleep

    var title: String {
        switch self {
        case .screenLock: "Screen lock"
        case .screenSaver: "Screen saver"
        case .displaySleep: "Display sleep"
        case .userSwitch: "User switch"
        case .systemSleep: "System sleep"
        }
    }

    var detail: String {
        switch self {
        case .screenLock: "When the screen locks. Drives come back when you unlock."
        case .screenSaver: "When the screen saver starts."
        case .displaySleep: "When the display goes to sleep."
        case .userSwitch: "When another user's session becomes active (fast user switching)."
        case .systemSleep: "Just before the Mac sleeps. Sleep is held briefly (see below), and a running Time Machine backup is never waited for."
        }
    }
}

/// A drive the user has seen, kept so it can be configured even while unplugged.
nonisolated struct KnownDrive: Codable, Hashable, Sendable {
    let key: String
    var name: String
    var encrypted: Bool? = nil
}

/// Settings that apply to one drive.
nonisolated struct DriveConfig: Codable, Equatable, Sendable {
    /// Wait this long after a trigger before unmounting. Ignored for system sleep, which can't wait.
    var delaySeconds = 0
    /// Triggers that must not unmount this drive.
    var disabledTriggers: Set<Trigger> = []
}

extension ManagedVolume {
    /// Stable identity for settings: the volume UUID, falling back to the name.
    nonisolated var key: String { volumeUUID ?? "name:\(name)" }
}

/// User preferences, persisted in UserDefaults.
///
/// Drives are opt-in: a drive is never unmounted until the user selects it.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let retryChoices = [15, 30, 60, 120]
    static let busyAttemptChoices = [1, 3, 5, 10]
    static let sleepHoldChoices = [5, 10, 15, 20, 25]
    static let driveDelayChoices = [0, 60, 300, 600, 1800]

    private(set) var enabledTriggers: Set<Trigger>
    private(set) var retrySeconds: Int
    private(set) var busyAttempts: Int
    private(set) var sleepHoldSeconds: Int
    private(set) var checkOpenFiles: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var selectedKeys: Set<String>
    private(set) var knownDrives: [KnownDrive]
    private(set) var driveConfigs: [String: DriveConfig]

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "retrySeconds": 30, "busyAttempts": 3, "sleepHoldSeconds": 10,
            "checkOpenFiles": true, "notificationsEnabled": true,
            "enabledTriggers": [Trigger.screenLock.rawValue],
        ])
        enabledTriggers = Set((defaults.stringArray(forKey: "enabledTriggers") ?? []).compactMap(Trigger.init))
        retrySeconds = defaults.integer(forKey: "retrySeconds")
        busyAttempts = defaults.integer(forKey: "busyAttempts")
        sleepHoldSeconds = defaults.integer(forKey: "sleepHoldSeconds")
        checkOpenFiles = defaults.bool(forKey: "checkOpenFiles")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        selectedKeys = Set(defaults.stringArray(forKey: "selectedDriveKeys") ?? [])
        knownDrives = defaults.data(forKey: "knownDrives")
            .flatMap { try? JSONDecoder().decode([KnownDrive].self, from: $0) } ?? []
        driveConfigs = defaults.data(forKey: "driveConfigs")
            .flatMap { try? JSONDecoder().decode([String: DriveConfig].self, from: $0) } ?? [:]
    }

    // MARK: Triggers and options

    func isEnabled(_ trigger: Trigger) -> Bool { enabledTriggers.contains(trigger) }

    func setEnabled(_ trigger: Trigger, _ on: Bool) {
        if on { enabledTriggers.insert(trigger) } else { enabledTriggers.remove(trigger) }
        defaults.set(enabledTriggers.map(\.rawValue), forKey: "enabledTriggers")
    }

    func setRetrySeconds(_ value: Int) {
        retrySeconds = max(5, value)
        defaults.set(retrySeconds, forKey: "retrySeconds")
    }

    func setBusyAttempts(_ value: Int) {
        busyAttempts = max(1, value)
        defaults.set(busyAttempts, forKey: "busyAttempts")
    }

    func setSleepHoldSeconds(_ value: Int) {
        // macOS proceeds with sleep ~30 s after asking apps to acknowledge it; stay inside that.
        sleepHoldSeconds = min(max(1, value), 25)
        defaults.set(sleepHoldSeconds, forKey: "sleepHoldSeconds")
    }

    func setCheckOpenFiles(_ value: Bool) {
        checkOpenFiles = value
        defaults.set(value, forKey: "checkOpenFiles")
    }

    func setNotificationsEnabled(_ value: Bool) {
        notificationsEnabled = value
        defaults.set(value, forKey: "notificationsEnabled")
    }

    // MARK: Drives

    func isSelected(_ volume: ManagedVolume) -> Bool {
        selectedKeys.contains(volume.key)
    }

    func setSelected(key: String, _ selected: Bool) {
        if selected { selectedKeys.insert(key) } else { selectedKeys.remove(key) }
        defaults.set(Array(selectedKeys), forKey: "selectedDriveKeys")
    }

    func config(for key: String) -> DriveConfig { driveConfigs[key] ?? DriveConfig() }

    func updateConfig(for key: String, _ change: (inout DriveConfig) -> Void) {
        var config = config(for: key)
        change(&config)
        driveConfigs[key] = config == DriveConfig() ? nil : config
        defaults.set(try? JSONEncoder().encode(driveConfigs), forKey: "driveConfigs")
    }

    func remember(_ volume: ManagedVolume) {
        let drive = KnownDrive(key: volume.key, name: volume.name, encrypted: volume.encrypted)
        if let index = knownDrives.firstIndex(where: { $0.key == drive.key }) {
            guard knownDrives[index] != drive else { return }
            knownDrives[index] = drive
        } else {
            knownDrives.append(drive)
        }
        defaults.set(try? JSONEncoder().encode(knownDrives), forKey: "knownDrives")
    }

    func forget(key: String) {
        knownDrives.removeAll { $0.key == key }
        selectedKeys.remove(key)
        driveConfigs[key] = nil
        defaults.set(try? JSONEncoder().encode(knownDrives), forKey: "knownDrives")
        defaults.set(Array(selectedKeys), forKey: "selectedDriveKeys")
        defaults.set(try? JSONEncoder().encode(driveConfigs), forKey: "driveConfigs")
    }
}
