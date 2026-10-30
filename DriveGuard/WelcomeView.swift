//
//  WelcomeView.swift
//  DriveGuard
//

import SwiftUI

/// Shown once, the first time DriveGuard opens.
struct WelcomeView: View {
    static let shownKey = "welcomeShown"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to DriveGuard").font(.title2.bold())

            Text("DriveGuard does nothing until you tick a drive. Tick the external drives you want it to look after in the list below. Anything you leave unticked is never touched.")

            Text("When you lock your Mac, DriveGuard unmounts the ticked drives safely: never forced, never ejected, and not during a Time Machine backup. When you come back, it mounts them again.")

            Divider()

            Text("Encrypted drives").font(.headline)
            Text("macOS locks an encrypted drive when it is unmounted, and DriveGuard needs two things to bring it back: its password, saved in your keychain from the drive's settings, and Full Disk Access. Without both, DriveGuard leaves that drive alone.")
            Text(FullDiskAccess.isGranted ? "Full Disk Access: on." : "Full Disk Access: not on yet. Only needed for encrypted drives.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Full Disk Access settings") { FullDiskAccess.openSettings() }

            HStack {
                Spacer()
                Button("Get started") {
                    UserDefaults.standard.set(true, forKey: Self.shownKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}
