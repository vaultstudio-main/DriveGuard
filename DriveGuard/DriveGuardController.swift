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
        let isEncrypted: Bool
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
    /// Every job that has been queued and has not finished. Jobs wait for the one before them, so
    /// cancelling only the newest would leave an older one still waiting on Time Machine.
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var activeReasons: Set<Trigger> = []
    private var tmDestinations: [TimeMachine.Destination] = []
    private var isPoweringOff = false

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
        disks.watchForNewDisks { DriveGuardController.shared.diskAppeared() }
        observe(workspace, NSWorkspace.didUnmountNotification.rawValue) { $0.refreshDrives() }
        observe(workspace, NSWorkspace.willPowerOffNotification.rawValue) { controller in
            controller.isPoweringOff = true
            controller.log.add("The Mac is shutting down or restarting; macOS will unmount the drives itself")
        }

        power.onWillSleep = { [unowned self] allow in systemWillSleep(allow: allow) }
        power.onDidWake = { [unowned self] in triggerEnded(.systemSleep) }
        power.start()

        refreshDrives()
        log.add("DriveGuard started")
        let present = disks.mountedExternalVolumes()
        if present.isEmpty {
            log.add("External drives at startup: none mounted")
        } else {
            log.add("External drives at startup: " + present.map { "\($0.name) (mounted)" }.joined(separator: ", "))
        }

        if !owedVolumes.isEmpty {
            log.add("Found \(owedVolumes.count) volume(s) left unmounted by a previous run", level: .warning)
            Notifier.shared.post(title: "Drives were left unmounted",
                                 body: "DriveGuard is remounting \(owedVolumes.count) volume(s) from a previous run.")
            enqueue { await $0.remountAll() }
        }
    }

    private var appearGeneration = 0

    /// A disk showed up (after a restart or a replug). If a drive is still owed and the Mac is not in the
    /// middle of being away, try to bring it back once the burst of events settles.
    private func diskAppeared() {
        guard started, !owedVolumes.isEmpty else { return }
        appearGeneration += 1
        let generation = appearGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, generation == self.appearGeneration else { return }
            self.remountOwedIfBack()
        }
    }

    private func remountOwedIfBack() {
        guard !owedVolumes.isEmpty, activeReasons.isEmpty, !isPoweringOff, jobs.isEmpty else { return }
        log.add("A drive appeared; checking the \(owedVolumes.count) drive(s) still waiting to be remounted")
        enqueue { await $0.remountAll() }
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
                       isTimeMachine: isTimeMachine($0), isEncrypted: $0.encrypted == true)
        }
        for known in settings.knownDrives where !mountedKeys.contains(known.key) {
            entries.append(DriveEntry(
                key: known.key, name: known.name, bsdName: nil,
                state: owedKeys.contains(known.key) ? .unmountedByDriveGuard : .notMounted,
                isTimeMachine: false, isEncrypted: known.encrypted == true
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
        cancelPendingWork() // stops all waiting/retrying; an unmount already in flight finishes first
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
        cancelPendingWork()
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

    /// True when quitting should first bring drives back. Not at shutdown or restart: macOS is
    /// unmounting everything itself then, and it mounts the drives again at startup.
    var needsRemountBeforeQuit: Bool { !owedVolumes.isEmpty && !isPoweringOff }

    /// Remounts what DriveGuard unmounted before the app quits, waiting at most 20 seconds.
    func remountBeforeQuit() async {
        log.add("Quitting: remounting \(owedVolumes.count) drive(s) first")
        activeReasons.removeAll()
        cancelPendingWork()
        enqueue { await $0.remountAll() }
        let work = job
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once { continuation.resume() }
            Task { await work?.value; once.fire() }
            Task { try? await Task.sleep(for: .seconds(20)); once.fire() }
        }
        if owedVolumes.isEmpty {
            log.add("DriveGuard quit: all drives are mounted")
        } else {
            log.add("DriveGuard quit before every drive was back; it will finish remounting next time it starts", level: .warning)
        }
    }

    // MARK: Drive passwords

    enum PasswordSave {
        case saved(verified: Bool, note: String?)
        case refused
        /// macOS will not let DriveGuard unlock drives yet (Full Disk Access): nothing was saved.
        case notPermitted
        case failed
    }

    /// Checks a password with macOS where it can, then keeps it in the keychain. A password macOS says is
    /// wrong is not saved, and neither is one while macOS forbids DriveGuard to unlock drives: unmounting a
    /// drive DriveGuard cannot bring back would strand it. The password is never written to the log.
    func savePassword(_ password: String, for drive: DriveEntry) async -> PasswordSave {
        var verified = false
        var note: String?
        if let bsd = drive.bsdName {
            let volume = ManagedVolume(bsdName: bsd, volumeUUID: drive.key.hasPrefix("name:") ? nil : drive.key,
                                       name: drive.name)
            switch await disks.verifyPassword(password, for: volume) {
            case .verified: verified = true
            case .wrong: return .refused
            case .notPermitted:
                log.add("macOS will not let DriveGuard unlock \"\(drive.name)\" (error -69464). DriveGuard needs Full Disk Access (System Settings > Privacy & Security > Full Disk Access), then quit and reopen it. Nothing was saved and the drive will not be unmounted.", level: .warning)
                return .notPermitted
            case .unverifiable(let why): note = why
            }
        }
        guard DrivePasswords.save(password, for: drive.key, label: "DriveGuard: \(drive.name)") else { return .failed }
        log.add("Saved a password for \"\(drive.name)\" in your keychain" + (verified ? " (checked with macOS)" : ""))
        return .saved(verified: verified, note: note)
    }

    func removePassword(for drive: DriveEntry) {
        DrivePasswords.remove(drive.key)
        log.add("Removed the saved password for \"\(drive.name)\"")
    }

    func unmountNow() {
        log.add("Manual unmount requested")
        enqueue { await $0.unmountAll(trigger: nil, mode: .normal) }
    }

    func remountNow() {
        log.add("Manual remount requested")
        activeReasons.removeAll()
        cancelPendingWork()
        enqueue { await $0.remountAll() }
    }

    func remount(key: String) {
        log.add("Manual remount requested for one drive")
        cancelPendingWork()
        enqueue { await $0.remountAll(onlyKey: key) }
    }

    private func enqueue(_ work: @escaping (DriveGuardController) async -> Void) {
        let previous = job
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
            self.jobs[id] = nil
        }
        jobs[id] = task
        job = task
    }

    /// Cancels everything waiting or retrying (not an unmount macOS is already carrying out).
    /// Jobs queued after this call are not affected.
    private func cancelPendingWork() {
        for task in jobs.values { task.cancel() }
    }

    // MARK: Unmount

    /// `trigger` is nil for a manual request, which ignores per-drive trigger and delay settings.
    private func unmountAll(trigger: Trigger?, mode: RunMode) async {
        if Task.isCancelled && mode == .normal { return } // you came back before this job got its turn
        let startedAt = Date()
        let external = disks.mountedExternalVolumes()
        external.forEach(settings.remember)

        let selected = external.filter(settings.isSelected)
        var volumes = selected.filter { volume in
            guard let trigger else { return true }
            return !settings.config(for: volume.key).disabledTriggers.contains(trigger)
        }
        // An encrypted drive locks when unmounted, and only its password opens it again. Without a saved
        // password DriveGuard could never bring it back, so it is left alone.
        // Even with a saved password, macOS refuses the unlock when Full Disk Access has been switched off.
        let canUnlock = FullDiskAccess.isGranted
        let locked = volumes.filter { $0.encrypted == true && (!DrivePasswords.has($0.key) || !canUnlock) }
        for volume in locked {
            if DrivePasswords.has(volume.key) {
                log.add("Skipped \"\(volume.name)\": it is encrypted and DriveGuard no longer has Full Disk Access, so it could not unlock the drive again. Switch DriveGuard on under System Settings > Privacy & Security > Full Disk Access, then quit and reopen it.", level: .warning)
            } else {
                log.add("Skipped \"\(volume.name)\": it is encrypted, and DriveGuard has no password to unlock it again. Add the password in the drive's settings (the slider button next to it).", level: .warning)
            }
        }
        volumes.removeAll { volume in locked.contains { $0.bsdName == volume.bsdName } }
        if volumes.isEmpty {
            if !locked.isEmpty { return }
            // Every maintenance wake fires the triggers; with no drives attached there is nothing worth a line.
            if external.isEmpty && trigger != nil { return }
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

            if result.timedOut {
                // The request is still out there and may yet complete, so keep the debt: the drive
                // is remounted (or found already mounted) when you come back.
                log.add("Unmount of \"\(volume.name)\" (\(volume.bsdName)): \(result.failure ?? "no answer"). It may still finish; DriveGuard will check when you return.", level: .error)
                Notifier.shared.post(title: "\(volume.name): macOS didn't answer", body: "The unmount request got no reply. DriveGuard will check the drive when you return.")
                return false
            }
            guard let reason = result.failure else {
                if let stillAt = disks.mountPath(of: volume) {
                    log.add("Unmount of \"\(volume.name)\" (\(volume.bsdName)) was reported as done, but it still shows as mounted at \(stillAt)", level: .warning)
                } else {
                    log.add("Unmounted \"\(volume.name)\" (\(volume.bsdName)). Confirmed: it is no longer mounted.")
                }
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

    /// Mount attempts per drive, and the pause between them. macOS often mounts a drive itself at the
    /// moment you unlock, and a request that lands at the same time can fail, so a second look helps.
    private static let remountAttempts = 3
    private static let remountPause: Duration = .seconds(3)

    private func remountAll(onlyKey: String? = nil) async {
        let pending = owedVolumes.filter { onlyKey == nil || $0.key == onlyKey }
        guard !pending.isEmpty else { return }
        log.add("Remounting \(pending.count) volume(s)")

        for volume in pending {
            await remount(volume)
        }
        refreshDrives()
    }

    /// Brings one volume back. It is taken off the to-do list only once it is mounted (or gone for good);
    /// a drive that could not be mounted stays on the list so the next try can finish the job.
    private func remount(_ volume: ManagedVolume) async {
        var failure = ""
        var shownName = volume.bsdName // the disk name can change after a restart; show the current one
        for attempt in 1...Self.remountAttempts {
            // The disk name can change after a restart; find the drive by its volume ID. A drive that is not
            // connected (yet) stays on the list, and is tried again when a disk appears.
            guard let current = await disks.resolve(volume) else {
                log.add("\"\(volume.name)\" is not connected right now. It stays on the list, and DriveGuard remounts it when it appears.", level: .warning)
                return
            }
            shownName = current.bsdName
            switch await disks.remount(current, password: { DrivePasswords.read(volume.key) }) {
            case .needsPassword:
                log.add("\"\(volume.name)\" is encrypted and locked, and DriveGuard has no password for it. Unlock it yourself (Disk Utility, or unplug and replug it), or save its password in the drive's settings and choose Remount All Drives Now.", level: .error)
                Notifier.shared.post(title: "\(volume.name) needs its password", body: "It is encrypted and locked. Unlock it in Disk Utility, or save its password in DriveGuard.")
                return
            case .notPermitted:
                log.add("macOS will not let DriveGuard unlock \"\(volume.name)\" (error -69464, \"restricted by Sandbox\"). This is a privacy permission, not the password: give DriveGuard Full Disk Access in System Settings > Privacy & Security, then quit and reopen it. Until then, unlock the drive yourself in Disk Utility. It stays on the list.", level: .error)
                Notifier.shared.post(title: "DriveGuard needs Full Disk Access", body: "macOS won't let it unlock \(volume.name). Unlock it in Disk Utility, or allow DriveGuard in Privacy & Security.")
                return
            case .wrongPassword:
                log.add("The password saved for \"\(volume.name)\" was refused. DriveGuard will not try it again. Update it in the drive's settings, then choose Remount All Drives Now.", level: .error)
                Notifier.shared.post(title: "\(volume.name): saved password refused", body: "Update the password in DriveGuard's drive settings.")
                return
            case .mounted(let path):
                if let path {
                    let how = volume.encrypted == true ? " It was unlocked and mounted." : ""
                    log.add("Remounted \"\(volume.name)\" (\(shownName)). Confirmed: it is mounted at \(path).\(how)")
                } else {
                    log.add("Remounted \"\(volume.name)\" (\(shownName)), but could not confirm where it is mounted", level: .warning)
                }
                removeOwed(volume)
                return
            case .alreadyMounted(let path):
                let where_ = path.map { " at \($0)" } ?? ""
                if attempt > 1 {
                    log.add("macOS mounted \"\(volume.name)\" (\(shownName)) itself while DriveGuard was trying. Confirmed: it is mounted\(where_).")
                } else {
                    log.add("\"\(volume.name)\" (\(shownName)) was already mounted\(where_). macOS may have mounted it itself, for example when you unlocked or after a restart.")
                }
                removeOwed(volume)
                return
            case .missing(let why):
                log.add("Skipped \"\(volume.name)\": \(why)", level: .warning)
                removeOwed(volume)
                return
            case .failed(let why):
                failure = why
                // macOS may have mounted it in the meantime (it often does at unlock).
                if let path = disks.mountPath(of: current) {
                    log.add("macOS mounted \"\(volume.name)\" (\(shownName)) itself while DriveGuard was trying (\(why)). Confirmed: it is mounted at \(path).")
                    removeOwed(volume)
                    return
                }
                if attempt < Self.remountAttempts {
                    log.add("Mounting \"\(volume.name)\" (\(shownName)) failed: \(why). Trying again (attempt \(attempt + 1) of \(Self.remountAttempts)).", level: .warning)
                    do { try await Task.sleep(for: Self.remountPause) } catch {
                        log.add("Cancelled while retrying \"\(volume.name)\"; it stays on the list to remount", level: .warning)
                        return
                    }
                }
            }
        }
        log.add("Remount of \"\(volume.name)\" (\(shownName)) failed after \(Self.remountAttempts) attempts: \(failure). It stays on the list; choose Remount All Drives Now to try again, or unplug and replug the drive.", level: .error)
        Notifier.shared.post(title: "Couldn't remount \(volume.name)", body: failure)
    }
}
