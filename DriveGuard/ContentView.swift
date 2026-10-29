//
//  ContentView.swift
//  DriveGuard
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole app in one small, fixed-size settings screen.
struct ContentView: View {
    private let controller = DriveGuardController.shared
    private let settings = AppSettings.shared
    private let loginItem = LoginItem.shared

    @State private var showingLog = false
    @State private var showingSafety = false
    @State private var showingTiming = false

    var body: some View {
        Form {
            statusSection
            DrivesSection()
            triggersSection
            optionsSection
            activitySection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .frame(width: 540, height: 870)
        .sheet(isPresented: $showingLog) { FullLogView() }
        .onAppear { loginItem.refresh() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Safety details", systemImage: "checkmark.shield") { showingSafety = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("What DriveGuard will and will never do")
                    .popover(isPresented: $showingSafety) { SafetyPopover() }
                if controller.isPaused {
                    Button("Resume") { controller.resume() }
                } else {
                    Menu("Pause") {
                        Button("For 1 hour") { controller.pause(for: 3600) }
                        Button("Until I resume") { controller.pause(for: nil) }
                    }
                    .fixedSize()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var statusSymbol: String {
        if controller.isPaused { return "pause.circle.fill" }
        return controller.owedVolumes.isEmpty ? "checkmark.shield.fill" : "externaldrive.badge.minus"
    }

    private var statusColor: Color {
        if controller.isPaused { return .orange }
        return controller.owedVolumes.isEmpty ? .green : .blue
    }

    private var statusTitle: String {
        if controller.isPaused { return "Paused" }
        let count = controller.owedVolumes.count
        return count == 0 ? "Watching" : "\(count) drive\(count == 1 ? "" : "s") unmounted"
    }

    private var statusDetail: String {
        if controller.isPaused { return "Nothing will be unmounted until you resume." }
        if !controller.owedVolumes.isEmpty {
            return controller.owedVolumes.map(\.name).joined(separator: ", ") + " · back when you return"
        }
        let on = Trigger.allCases.filter(settings.isEnabled).map { $0.title.lowercased() }
        let chosen = settings.selectedKeys.count
        if chosen == 0 { return "No drives selected yet. Tick one below." }
        return "\(chosen) drive\(chosen == 1 ? "" : "s") on " + (on.isEmpty ? "no triggers" : on.joined(separator: ", "))
    }

    // MARK: Triggers

    private var triggersSection: some View {
        Section("Unmount when") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(Trigger.allCases, id: \.self) { trigger in
                    Toggle(trigger.title, isOn: Binding(
                        get: { settings.isEnabled(trigger) },
                        set: { settings.setEnabled(trigger, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .help(trigger.detail)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.set($0) }
            ))
            if loginItem.needsApproval {
                Text("Approve DriveGuard in System Settings > General > Login Items.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Notify me when something fails", isOn: Binding(
                get: { settings.notificationsEnabled },
                set: {
                    settings.setNotificationsEnabled($0)
                    if $0 { Notifier.shared.requestAuthorization() }
                }
            ))
            Toggle("Wait if a program is writing to a drive", isOn: Binding(
                get: { settings.checkOpenFiles },
                set: { settings.setCheckOpenFiles($0) }
            ))
            .help("Checks for open files before asking macOS to unmount. Only sees your own programs; macOS still has the final say.")

            DisclosureGroup("Timing", isExpanded: $showingTiming) {
                Picker("Recheck Time Machine every", selection: Binding(
                    get: { settings.retrySeconds },
                    set: { settings.setRetrySeconds($0) }
                )) {
                    ForEach(AppSettings.retryChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Attempts for a busy drive", selection: Binding(
                    get: { settings.busyAttempts },
                    set: { settings.setBusyAttempts($0) }
                )) {
                    ForEach(AppSettings.busyAttemptChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Hold sleep for up to", selection: Binding(
                    get: { settings.sleepHoldSeconds },
                    set: { settings.setSleepHoldSeconds($0) }
                )) {
                    ForEach(AppSettings.sleepHoldChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .help("Only used by the System sleep trigger. A busy drive is retried every 5 s within this time. macOS itself only waits about 30 s for apps before sleeping, so 25 s is the most DriveGuard can safely hold.")
            }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        let log = controller.log
        return Section {
            // Fixed height so new events never resize the form and make everything above it jump.
            VStack(alignment: .leading, spacing: 8) {
                if log.entries.isEmpty {
                    Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(log.entries.suffix(3)) { entry in
                    LogRow(entry: entry, singleLine: true)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 3 * 20 + 2 * 8, alignment: .top)
            .padding(.vertical, 6)
            Button("Open full log…") { showingLog = true }
        } header: {
            Text("Recent activity")
        }
    }
}

// MARK: Status bar

/// Pinned to the bottom of the window: monitor state on the left, Time Machine on the right.
struct StatusBar: View {
    private let controller = DriveGuardController.shared
    private let settings = AppSettings.shared

    @State private var backup: TimeMachine.BackupState?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Label(backupText, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .help("Time Machine status, checked every 15 seconds while this window is open")
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .frame(height: 32)
        }
        .background(.bar)
        .task {
            while !Task.isCancelled {
                backup = await TimeMachine.backupState()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var color: Color {
        if controller.isPaused { return .orange }
        return controller.owedVolumes.isEmpty ? .green : .blue
    }

    private var title: String {
        if controller.isPaused { return "Paused" }
        let count = controller.owedVolumes.count
        return count == 0 ? "Monitoring" : "\(count) unmounted"
    }

    private var detail: String {
        let chosen = settings.selectedKeys.count
        return chosen == 0 ? "no drives selected" : "\(chosen) drive\(chosen == 1 ? "" : "s") selected"
    }

    private var backupText: String {
        switch backup {
        case .idle: "Time Machine idle"
        case .running: "Backing up"
        case .unknown: "Time Machine unknown"
        case nil: "Checking…"
        }
    }
}

// MARK: Log

struct LogRow: View {
    let entry: EventLog.Entry
    var singleLine = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.message)
                .lineLimit(singleLine ? 1 : nil)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var symbol: String {
        switch entry.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

struct FullLogView: View {
    @Environment(\.dismiss) private var dismiss
    private let log = DriveGuardController.shared.log

    var body: some View {
        VStack(spacing: 0) {
            // Header is outside the scrolling area, so it stays put however the log changes.
            HStack {
                Text("Activity log").font(.headline)
                Spacer()
                Button("Export…", systemImage: "square.and.arrow.up") { export() }
                    .disabled(log.entries.isEmpty)
                Button("Clear", systemImage: "trash") { log.clear() }
                    .disabled(log.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            // Oldest first, newest at the bottom: new events append instead of pushing every row down.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(log.entries) { entry in
                            LogRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding()
                }
                .overlay {
                    if log.entries.isEmpty {
                        ContentUnavailableView("No events yet", systemImage: "list.bullet.rectangle")
                    }
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: log.entries.count) { scrollToEnd(proxy) }
            }
        }
        .frame(width: 560, height: 420)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DriveGuard Log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let stamp = ISO8601DateFormatter()
        let text = log.entries.map { entry in
            "\(stamp.string(from: entry.date)) [\(String(describing: entry.level).uppercased())] \(entry.message)"
        }.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.add("Could not export log: \(error.localizedDescription)", level: .error)
        }
    }
}

#Preview {
    ContentView()
}
