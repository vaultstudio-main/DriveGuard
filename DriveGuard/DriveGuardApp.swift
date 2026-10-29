//
//  DriveGuardApp.swift
//  DriveGuard
//
//  Created by Donald A Stibich on 10/29/26.
//

import SwiftUI

@main
struct DriveGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let controller = DriveGuardController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: menuBarSymbol)
        }

        Window("DriveGuard", id: AppWindow.mainID) {
            MainWindowContent()
        }
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentSize)

        Window("DriveGuard Help", id: AppWindow.helpID) {
            HelpView()
                .onAppear { DockPresence.windowOpened() }
                .onDisappear { DockPresence.windowClosed() }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .commands { AppMenuCommands() }

        Window("About DriveGuard", id: AppWindow.aboutID) {
            AboutWindow()
                .onAppear { DockPresence.windowOpened() }
                .onDisappear { DockPresence.windowClosed() }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    private var menuBarSymbol: String {
        if controller.isPaused { return "pause.circle" }
        if !controller.owedVolumes.isEmpty { return "externaldrive.badge.minus" }
        return "externaldrive.badge.checkmark"
    }
}

enum AppWindow {
    static let mainID = "main"
    static let helpID = "help"
    static let aboutID = "about"
}

/// Switches between menu-bar-only (.accessory) and Dock-visible (.regular)
/// depending on whether the main window is open.
@MainActor
enum DockPresence {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        bringToFront()
    }

    /// The settings window, if it exists (status-item and popup windows are untitled).
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "DriveGuard" && $0.styleMask.contains(.titled) }
    }

    /// Opens the window if needed and brings it in front. An accessory app can't take focus until it
    /// has become a regular app, so the policy is switched first, and focus is retried once the
    /// window has actually been created.
    static func showMainWindow(open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            open()
        }
        bringToFront()
    }

    private static func bringToFront() {
        NSApp.activate()
        for delay in [0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate()
                // Works even when macOS refuses to make us the active app (e.g. another app is frontmost).
                mainWindow?.orderFrontRegardless()
                mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Wraps the settings screen: handles Dock presence and stays hidden when macOS started us at login.
private struct MainWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentView()
            .onAppear {
                if AppDelegate.launchedAtLogin && !AppDelegate.handledLoginLaunch {
                    AppDelegate.handledLoginLaunch = true
                    dismissWindow(id: AppWindow.mainID)
                    return
                }
                DockPresence.windowOpened()
            }
            .onDisappear { DockPresence.windowClosed() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the system launched us as a login item, in which case we stay in the menu bar.
    static var launchedAtLogin = false
    static var handledLoginLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        Self.launchedAtLogin = reason == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuTrimmer.install()
        DriveGuardController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quit brings back any drives DriveGuard unmounted before it exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = DriveGuardController.shared
        guard controller.needsRemountBeforeQuit else {
            controller.log.add("DriveGuard quit")
            return .terminateNow
        }
        Task { @MainActor in
            await controller.remountBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    private let controller = DriveGuardController.shared
    private let loginItem = LoginItem.shared

    var body: some View {
        Button("Open DriveGuard…") {
            DockPresence.showMainWindow { openWindow(id: AppWindow.mainID) }
        }
        .keyboardShortcut(",")

        Divider()

        if controller.owedVolumes.isEmpty {
            Text("No drives unmounted")
        } else {
            Text("Unmounted by DriveGuard:")
            ForEach(controller.owedVolumes, id: \.bsdName) { volume in
                Button("Remount \(volume.name)") { controller.remount(key: volume.key) }
            }
        }

        Divider()

        Button("Unmount Selected Drives Now") { controller.unmountNow() }
        Button("Remount All Drives Now") { controller.remountNow() }

        Divider()

        if controller.isPaused {
            Button("Resume DriveGuard") { controller.resume() }
        } else {
            Button("Pause for 1 Hour") { controller.pause(for: 3600) }
            Button("Pause Until Resumed") { controller.pause(for: nil) }
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.set($0) }
        ))

        Divider()

        Button("Quit DriveGuard") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
