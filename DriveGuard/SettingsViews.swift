//
//  SettingsViews.swift
//  DriveGuard
//

import SwiftUI

// MARK: Drives

struct DrivesSection: View {
    private let controller = DriveGuardController.shared
    private let settings = AppSettings.shared

    @State private var configuring: String?

    var body: some View {
        Section {
            if controller.drives.isEmpty {
                Text("No external drives found. Plug one in and it will appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(controller.drives) { drive in
                row(drive)
            }
        } header: {
            Text("Drives DriveGuard may unmount")
        } footer: {
            Text("Off by default. Unchecked drives are never touched.")
        }
        .onAppear { controller.refreshDrives() }
    }

    private func row(_ drive: DriveGuardController.DriveEntry) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { settings.selectedKeys.contains(drive.key) },
                set: { settings.setSelected(key: drive.key, $0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(drive.name)
                        if drive.isTimeMachine {
                            Label("Time Machine", systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                        if drive.isEncrypted {
                            Label("Encrypted", systemImage: "lock.fill")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(statusText(drive)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .disabled(drive.isEncrypted)
            Spacer()
            if drive.state == .unmountedByDriveGuard {
                Button("Remount") { controller.remount(key: drive.key) }
            }
            Button("Drive settings", systemImage: "slider.horizontal.3") { configuring = drive.key }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delay and per-trigger settings for this drive")
                .popover(isPresented: Binding(
                    get: { configuring == drive.key },
                    set: { if !$0 { configuring = nil } }
                )) {
                    DriveConfigView(drive: drive)
                }
            if drive.state == .notMounted {
                Button("Forget", systemImage: "xmark.circle") {
                    settings.forget(key: drive.key)
                    controller.refreshDrives()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove this drive from the list")
            }
        }
    }

    private func statusText(_ drive: DriveGuardController.DriveEntry) -> String {
        var text: String
        switch drive.state {
        case .mounted: text = "Mounted"
        case .unmountedByDriveGuard: text = "Unmounted by DriveGuard"
        case .notMounted: text = "Not connected"
        }
        if drive.isEncrypted {
            text += " · left mounted (encrypted)"
        }
        let config = settings.config(for: drive.key)
        if config.delaySeconds > 0 { text += " · waits \(delayLabel(config.delaySeconds))" }
        if !config.disabledTriggers.isEmpty { text += " · custom triggers" }
        return text
    }
}

private func delayLabel(_ seconds: Int) -> String {
    seconds == 0 ? "Immediately" : seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) min"
}

private struct DriveConfigView: View {
    let drive: DriveGuardController.DriveEntry
    private let settings = AppSettings.shared

    var body: some View {
        Form {
            Section(drive.name) {
                Picker("Wait after trigger", selection: Binding(
                    get: { settings.config(for: drive.key).delaySeconds },
                    set: { value in settings.updateConfig(for: drive.key) { $0.delaySeconds = value } }
                )) {
                    ForEach(AppSettings.driveDelayChoices, id: \.self) { Text(delayLabel($0)).tag($0) }
                }
                Text("Doesn't apply to system sleep, which can't wait.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Unmount this drive on") {
                ForEach(Trigger.allCases, id: \.self) { trigger in
                    Toggle(trigger.title, isOn: Binding(
                        get: { !settings.config(for: drive.key).disabledTriggers.contains(trigger) },
                        set: { on in
                            settings.updateConfig(for: drive.key) {
                                if on { $0.disabledTriggers.remove(trigger) } else { $0.disabledTriggers.insert(trigger) }
                            }
                        }
                    ))
                }
                Text("Only triggers switched on in the main list ever fire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 380, height: 460)
    }
}

// MARK: Safety

struct SafetyPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DriveGuard will").font(.headline)
            item("checkmark.circle.fill", .green, "Unmount only the drives you ticked")
            item("checkmark.circle.fill", .green, "Wait while Time Machine is backing up (or if it can't tell)")
            item("checkmark.circle.fill", .green, "Wait for a program that is writing to a drive")
            item("checkmark.circle.fill", .green, "Retry a busy drive, then leave it mounted and notify you")
            item("checkmark.circle.fill", .green, "Name the programs holding a drive open")
            item("checkmark.circle.fill", .green, "Remount when you're back, and after a crash or relaunch")

            Text("DriveGuard will never").font(.headline).padding(.top, 8)
            item("xmark.circle.fill", .red, "Force an unmount, even if a drive stays busy")
            item("xmark.circle.fill", .red, "Eject a drive (it only unmounts)")
            item("xmark.circle.fill", .red, "Unmount during a backup; before sleep it skips the drive")
            item("xmark.circle.fill", .red, "Hold sleep past your limit, or veto it")
            item("xmark.circle.fill", .red, "Touch the startup disk, internal drives, network shares or disk images")
        }
        .font(.callout)
        .padding(24)
        .frame(width: 420)
    }

    private func item(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}
