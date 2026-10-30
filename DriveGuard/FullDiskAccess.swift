//
//  FullDiskAccess.swift
//  DriveGuard
//

import AppKit
import Darwin

/// Whether macOS has given DriveGuard Full Disk Access, which it requires before `diskutil` will unlock
/// an encrypted drive for us.
nonisolated enum FullDiskAccess {
    /// Opening (not reading) the privacy database succeeds only with the permission, and changes nothing.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
