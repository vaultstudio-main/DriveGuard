//
//  HelpView.swift
//  DriveGuard
//

import SwiftUI

/// Short in-app guide, opened from Help > DriveGuard Help.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topic("What DriveGuard does", """
                    DriveGuard safely unmounts your external drives when you step away, so they stop \
                    waking your Mac and a Time Machine drive isn't left mounted when the Mac sleeps. \
                    When you come back, it mounts them again. It never ejects and never forces anything.
                    """)

                topic("Getting started", """
                    1. Tick the drives you want DriveGuard to manage. Nothing is touched until you do.
                    2. Choose when to unmount: screen lock, screen saver, display sleep, user switch \
                    or system sleep.
                    3. That's it. DriveGuard runs from the menu bar; closing this window doesn't quit it.
                    """)

                topic("Time Machine", """
                    DriveGuard checks Time Machine before every unmount. If a backup is running, or it \
                    can't tell, it waits and checks again. Just before sleep it can't wait, so it skips \
                    the drive instead.
                    """)

                topic("If a drive won't unmount", """
                    macOS refuses when something is using the drive. DriveGuard never forces it. It \
                    retries a few times, names the programs holding the drive open in the activity \
                    log, then leaves it mounted and notifies you.
                    """)

                topic("Per-drive settings", """
                    The slider button next to a drive sets a delay after the trigger, and which \
                    triggers apply to that drive.
                    """)

                topic("Pause", """
                    Pause stops DriveGuard from unmounting anything, for an hour or until you resume. \
                    Drives it already unmounted still come back.
                    """)

                topic("If drives stay unmounted", """
                    Use "Remount All Drives Now" in the menu bar menu, or the Remount button on the \
                    drive. After a quit or crash, DriveGuard remounts leftovers next time it starts.
                    """)

                topic("Launch at login", """
                    Works best when DriveGuard is in your Applications folder. It stays in the menu \
                    bar without opening this window.
                    """)

                VStack(alignment: .leading, spacing: 6) {
                    Text("License").font(.headline)
                    Text("""
                        DriveGuard is free software from Vault Studio. You can use, share and change it \
                        under the terms of the GNU General Public License, version 3. It comes without \
                        any warranty.
                        """)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: AboutInfo.licenseURL) {
                        Label("Read the full license", systemImage: "doc.text")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 500, height: 600)
    }

    private func topic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
