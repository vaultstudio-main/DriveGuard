//
//  DriveGuardController.swift
//  DriveGuard
//

import AppKit
import Foundation
import Observation

/// Owns the log and the unmount/remount workflow.
///
/// Unmount/remount work is serialized: each new job waits for the previous one to finish,
/// so a remount never races an in-flight unmount.
@MainActor
@Observable
final class DriveGuardController {
    static let shared = DriveGuardController()

    private static let defaultsKey = "unmountedVolumes"
    private static let sleepRetrySeconds = 5

    struct DriveEntry: Identifiable {
        enum State { case mounted, unmountedByDriveGuard, notMounted }
        let key: String
        let name: String
        let bsdName: String?
        let state: State
        let isTimeMachine: Bool
        var id: String { key }
    }

    private enum RunMode {
        /// Normal triggers: may wait for Time Machine and retry busy drives.
        case normal
        /// About to sleep: one quick attempt, never waits.
        case sleep
    }

    /// Makes sure a closure runs once (acknowledging sleep must happen exactly once).
    private final class Once {
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        func fire() { action?(); action = nil }
    }

    let log = EventLog()
    let settings = AppSettings.shared

    /// What the Drives tab shows: mounted external volumes plus drives seen before.
    private(set) var drives: [DriveEntry] = []

    /// Volumes we unmounted and still owe a remount. Persisted so a quit or crash can't strand them.
    private(set) var owedVolumes: [ManagedVolume]

    /// While in the future, triggers leave drives alone.
    private(set) var pausedUntil: Date?
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private let disks = DiskManager()
    private let power = PowerMonitor()
    private var job: Task<Void, Never>?
    private var started = false
    private var activeReasons: Set<Trigger> = []
    private var tmDestinations: [TimeMachine.Destination] = []

    private init() {
        owedVolumes = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([ManagedVolume].self, from: $0) } ?? []
    }

    private func addOwed(_ volume: ManagedVolume) {
        owedVolumes.append(volume)
        persistOwed()
    }

    private func removeOwed(_ volume: ManagedVolume) {
        owedVolumes.removeAll { $0.bsdName == volume.bsdName }
        persistOwed()
    }

    private func persistOwed() {
        UserDefaults.standard.set(try? JSONEncoder().encode(owedVolumes), forKey: Self.defaultsKey)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        Notifier.shared.start()
        if settings.notificationsEnabled { Notifier.shared.requestAuthorization() }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.triggerBegan(.screenLock) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.triggerEnded(.screenLock) }
        observe(distributed, "com.apple.screensaver.didstart") { $0.triggerBegan(.screenSaver) }
        observe(distributed, "com.apple.screensaver.didstop") { $0.triggerEnded(.screenSaver) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.triggerBegan(.displaySleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.triggerEnded(.displaySleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.triggerBegan(.userSwitch) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.triggerEnded(.userSwitch) }
        observe(workspace, NSWorkspace.didMountNotification.rawValue) { $0.refreshDrives() }
        observe(workspace, NSWorkspace.didUnmountNotification.rawValue) { $0.refreshDrives() }

        power.onWillSleep = { [unowned self] allow in systemWillSleep(allow: allow) }
        power.onDidWake = { [unowned self] in triggerEnded(.systemSleep) }
        power.start()

        refreshDrives()
        log.add("DriveGuard started")

        if !owedVolumes.isEmpty {
            log.add("Found \(owedVolumes.count) volume(s) left unmounted by a previous run", level: .warning)
            Notifier.shared.post(title: "Drives were left unmounted",
                                 body: "DriveGuard is remounting \(owedVolumes.count) volume(s) from a previous run.")
            enqueue { await $0.remountAll() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String,
                         _ action: @escaping @MainActor (DriveGuardController) -> Void) {
        center.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
            Task { @MainActor in action(DriveGuardController.shared) }
        }
    }

    // MARK: Drives list

    func refreshDrives() {
        rebuildDrives()
        Task {
            let latest = await TimeMachine.destinations()
            if latest != tmDestinations {
                tmDestinations = latest
                rebuildDrives()
            }
        }
    }

    private func rebuildDrives() {
        let mounted = disks.mountedExternalVolumes()
        mounted.forEach(settings.remember)
        let mountedKeys = Set(mounted.map(\.key))
        let owedKeys = Set(owedVolumes.map(\.key))

        var entries = mounted.map {
            DriveEntry(key: $0.key, name: $0.name, bsdName: $0.bsdName, state: .mounted,
                       isTimeMachine: isTimeMachine($0))
        }
        for known in settings.knownDrives where !mountedKeys.contains(known.key) {
            entries.append(DriveEntry(
                key: known.key, name: known.name, bsdName: nil,
                state: owedKeys.contains(known.key) ? .unmountedByDriveGuard : .notMounted,
                isTimeMachine: false
            ))
        }
        drives = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isTimeMachine(_ volume: ManagedVolume) -> Bool {
        tmDestinations.contains {
            ($0.mountPoint != nil && $0.mountPoint == volume.mountPath)
                || $0.id.caseInsensitiveCompare(volume.volumeUUID ?? "") == .orderedSame
        }
    }

    // MARK: Pause

    func pause(for interval: TimeInterval?) {
        pausedUntil = interval.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let interval {
            log.add("Paused for \(Int(interval / 60)) minutes")
        } else {
            log.add("Paused until resumed")
        }
    }

    func resume() {
        pausedUntil = nil
        log.add("Resumed")
    }

    // MARK: Triggers

    func triggerBegan(_ trigger: Trigger) {
        log.add("\(trigger.title) began")
        guard settings.isEnabled(trigger) else { return }
        guard !isPaused else {
            log.add("Paused; leaving drives alone")
            return
        }
        activeReasons.insert(trigger)
        enqueue { await $0.unmountAll(trigger: trigger, mode: .normal) }
    }

    func triggerEnded(_ trigger: Trigger) {
        log.add("\(trigger.title) ended")
        if trigger == .screenLock {
            activeReasons.removeAll() // unlocking is definitive: you're back at the Mac
        } else {
            activeReasons.remove(trigger)
        }
        guard activeReasons.isEmpty else {
            log.add("Still active: " + activeReasons.map(\.title).sorted().joined(separator: ", ") + "; drives stay unmounted")
            return
        }
        job?.cancel() // stops any waiting/retrying; an unmount already in flight finishes first
        enqueue { await $0.remountAll() }
    }

    private func systemWillSleep(allow: @escaping () -> Void) {
        let gate = Once(allow)
        guard settings.isEnabled(.systemSleep), !isPaused else {
            gate.fire()
            return
        }
        log.add("System going to sleep")
        activeReasons.insert(.systemSleep)
        job?.cancel()
        enqueue { controller in
            await controller.unmountAll(trigger: .systemSleep, mode: .sleep)
            gate.fire()
        }
        // Hard deadline: never hold sleep longer than the user's limit, whatever the unmount is doing.
        let hold = settings.sleepHoldSeconds
        let sleepJob = job
        Task {
            try? await Task.sleep(for: .seconds(hold))
            gate.fire()
            // Out of time: stop retrying so nothing is unmounted after we wake.
            sleepJob?.cancel()
        }
    }

    func unmountNow() {
        log.add("Manual unmount requested")
        enqueue { await $0.unmountAll(trigger: nil, mode: .normal) }
    }

    func remountNow() {
        log.add("Manual remount requested")
        activeReasons.removeAll()
        job?.cancel()
        enqueue { await $0.remountAll() }
    }

    func remount(key: String) {
        log.add("Manual remount requested for one drive")
        job?.cancel()
        enqueue { await $0.remountAll(onlyKey: key) }
    }

    private func enqueue(_ work: @escaping (DriveGuardController) async -> Void) {
        let previous = job
        job = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    // MARK: Unmount

    /// `trigger` is nil for a manual request, which ignores per-drive trigger and delay settings.
    private func unmountAll(trigger: Trigger?, mode: RunMode) async {
        let startedAt = Date()
        let external = disks.mountedExternalVolumes()
        external.forEach(settings.remember)

        let selected = external.filter(settings.isSelected)
        var volumes = selected.filter { volume in
            guard let trigger else { return true }
            return !settings.config(for: volume.key).disabledTriggers.contains(trigger)
        }
        if volumes.isEmpty {
            log.add(external.isEmpty
                ? "No external volumes mounted"
                : selected.isEmpty
                    ? "No selected drives mounted; left \(external.count) unselected drive(s) alone"
                    : "No drives are set to unmount on \(trigger?.title.lowercased() ?? "this request")")
            return
        }
        let skipped = external.count - volumes.count
        if skipped > 0 { log.add("Leaving \(skipped) other drive(s) mounted") }

        func delay(_ volume: ManagedVolume) -> Int {
            trigger == nil || mode == .sleep ? 0 : settings.config(for: volume.key).delaySeconds
        }
        volumes.sort { delay($0) < delay($1) }
        log.add("Unmounting \(volumes.count) volume(s): " + volumes.map(\.name).joined(separator: ", "))

        for volume in volumes {
            let remaining = Double(delay(volume)) - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                log.add("Waiting \(Int(remaining)) s before unmounting \"\(volume.name)\" (its delay setting)")
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    log.add("Cancelled before unmounting \"\(volume.name)\"; nothing changed")
                    return
                }
            }
            if Task.isCancelled && mode == .normal {
                log.add("Cancelled before unmounting \"\(volume.name)\"; nothing changed")
                return
            }
            // It may have been unplugged or unmounted by someone else while we waited.
            guard disks.mountedExternalVolumes().contains(where: { $0.bsdName == volume.bsdName }) else {
                log.add("\"\(volume.name)\" is no longer mounted; skipping")
                continue
            }
            _ = await attemptUnmount(volume, mode: mode)
        }
        refreshDrives()
    }

    /// Tries to unmount one volume, retrying only when it is busy. Returns true if it was unmounted.
    private func attemptUnmount(_ volume: ManagedVolume, mode: RunMode) async -> Bool {
        // Before sleep, retry a busy drive every few seconds for as long as the hold allows.
        let attempts = mode == .sleep ? max(1, settings.sleepHoldSeconds / Self.sleepRetrySeconds) : settings.busyAttempts
        var lastProblem = ""

        for attempt in 1...attempts {
            if Task.isCancelled { return false }
            guard await backupIsIdle(mode: mode) else { return false }

            // Pre-check: don't even ask macOS while something is actively writing to the drive.
            if settings.checkOpenFiles, let path = volume.mountPath,
               let open = await OpenFiles.list(onVolume: path) {
                let writers = open.filter { $0.isWriter && !$0.isBackgroundNoise }
                if !writers.isEmpty {
                    lastProblem = "files are being written by " + OpenFiles.summary(writers)
                    log.add("Not unmounting \"\(volume.name)\" yet: \(lastProblem)", level: .warning)
                    if !(await waitBeforeRetry(attempt: attempt, of: attempts, volume: volume, mode: mode)) { return false }
                    continue
                }
            }

            addOwed(volume) // record the debt first so a crash mid-unmount can't strand the drive
            let result = await disks.unmount(volume)
            guard let reason = result.failure else {
                log.add("Unmounted \"\(volume.name)\" (\(volume.bsdName))")
                return true
            }
            removeOwed(volume)

            guard result.busy else {
                log.add("Unmount of \"\(volume.name)\" (\(volume.bsdName)) refused: \(reason)", level: .error)
                Notifier.shared.post(title: "Couldn't unmount \(volume.name)", body: reason)
                return false
            }

            lastProblem = reason
            var message = "Unmount of \"\(volume.name)\" refused: \(reason)"
            if let path = volume.mountPath, let open = await OpenFiles.list(onVolume: path) {
                let holders = open.filter { !$0.isBackgroundNoise }
                if !holders.isEmpty { message += ". Held open by \(OpenFiles.summary(holders))" }
            }
            log.add(message, level: .warning)
            if !(await waitBeforeRetry(attempt: attempt, of: attempts, volume: volume, mode: mode)) { return false }
        }

        let text = mode == .sleep
            ? "\"\(volume.name)\" was left mounted for sleep: \(lastProblem)"
            : "Gave up unmounting \"\(volume.name)\" after \(attempts) attempt(s): \(lastProblem)"
        log.add(text, level: .error)
        Notifier.shared.post(title: "\(volume.name) was left mounted", body: lastProblem)
        return false
    }

    /// Waits between attempts. Returns false if cancelled. On the last attempt it returns
    /// immediately so the caller's loop ends and reports the failure.
    private func waitBeforeRetry(attempt: Int, of attempts: Int, volume: ManagedVolume, mode: RunMode) async -> Bool {
        guard attempt < attempts else { return true }
        let wait = mode == .sleep ? Self.sleepRetrySeconds : settings.retrySeconds
        log.add("Retrying \"\(volume.name)\" in \(wait) s (attempt \(attempt + 1) of \(attempts))")
        do {
            try await Task.sleep(for: .seconds(wait))
            return true
        } catch {
            log.add("Cancelled while waiting to retry \"\(volume.name)\"; nothing more unmounted")
            return false
        }
    }

    /// True once Time Machine is confirmed idle. Normal mode waits (indefinitely) and returns false
    /// only if cancelled; sleep mode checks once. An indeterminate answer counts as "backing up".
    private func backupIsIdle(mode: RunMode) async -> Bool {
        while true {
            if Task.isCancelled && mode == .normal {
                log.add("Cancelled before unmounting; nothing changed")
                return false
            }
            switch await TimeMachine.backupState() {
            case .idle:
                return true
            case .running:
                if mode == .sleep {
                    log.add("Time Machine is backing up; not unmounting before sleep", level: .warning)
                    return false
                }
                log.add("Time Machine backup in progress; retrying in \(settings.retrySeconds) s", level: .warning)
            case .unknown(let why):
                if mode == .sleep {
                    log.add("Can't confirm Time Machine is idle (\(why)); not unmounting before sleep", level: .warning)
                    return false
                }
                log.add("Can't confirm Time Machine is idle (\(why)); retrying in \(settings.retrySeconds) s", level: .warning)
            }
            do {
                try await Task.sleep(for: .seconds(settings.retrySeconds))
            } catch {
                log.add("Cancelled while waiting for Time Machine; nothing unmounted")
                return false
            }
        }
    }

    // MARK: Remount

    private func remountAll(onlyKey: String? = nil) async {
        let pending = owedVolumes.filter { onlyKey == nil || $0.key == onlyKey }
        guard !pending.isEmpty else { return }
        log.add("Remounting \(pending.count) volume(s)")

        for volume in pending {
            switch await disks.remount(volume) {
            case .mounted:
                log.add("Remounted \"\(volume.name)\" (\(volume.bsdName))")
            case .alreadyMounted:
                log.add("\"\(volume.name)\" is already mounted")
            case .missing(let why):
                log.add("Skipped \"\(volume.name)\": \(why)", level: .warning)
            case .failed(let why):
                log.add("Remount of \"\(volume.name)\" (\(volume.bsdName)) failed: \(why)", level: .error)
                Notifier.shared.post(title: "Couldn't remount \(volume.name)", body: why)
            }
            removeOwed(volume)
        }
        refreshDrives()
    }
}
