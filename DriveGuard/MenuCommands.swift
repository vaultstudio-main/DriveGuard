//
//  MenuCommands.swift
//  DriveGuard
//

import AppKit
import SwiftUI

/// Pared-down app menu: no Services or Hide items (they mean nothing for this app), a Help item.
struct AppMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DriveGuard") { openWindow(id: AppWindow.aboutID) }
        }
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .help) {
            Button("DriveGuard Help") {
                openWindow(id: AppWindow.helpID)
            }
        }
    }
}

/// SwiftUI always adds Edit, View and Window to the menu bar, and offers no way to drop them. This removes
/// them (and any leftover app-menu items) from the real menu, and again whenever SwiftUI rebuilds it.
@MainActor
enum MenuTrimmer {
    private static let removedMenus: Set<String> = ["Edit", "View", "Window"]
    private static let removedAppItems: Set<String> = ["Services", "Hide DriveGuard", "Hide Others", "Show All"]

    static func install() {
        trimSoon()
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in MenuTrimmer.trimSoon() }
            }
        }
    }

    /// SwiftUI rebuilds the menu asynchronously, so trim a few times as it settles.
    private static func trimSoon() {
        for delay in [0.0, 0.2, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MenuTrimmer.trim() }
        }
    }

    static func trim() {
        guard let main = NSApp.mainMenu else { return }
        for item in main.items where removedMenus.contains(item.title) {
            main.removeItem(item)
        }
        if let appMenu = main.items.first?.submenu {
            for item in appMenu.items where removedAppItems.contains(item.title) {
                appMenu.removeItem(item)
            }
            // Drop separators left stacked up or dangling by the removals.
            var previousWasSeparator = true
            for item in appMenu.items {
                if item.isSeparatorItem {
                    if previousWasSeparator { appMenu.removeItem(item) }
                    previousWasSeparator = true
                } else {
                    previousWasSeparator = false
                }
            }
            if let last = appMenu.items.last, last.isSeparatorItem { appMenu.removeItem(last) }
        }
    }
}
