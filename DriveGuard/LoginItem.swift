//
//  LoginItem.swift
//  DriveGuard
//

import Observation
import ServiceManagement

/// Launch-at-login state, shared by the menu and the settings window.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var needsApproval = SMAppService.mainApp.status == .requiresApproval

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enable: Bool) {
        let service = SMAppService.mainApp
        let log = DriveGuardController.shared.log
        do {
            if enable { try service.register() } else { try service.unregister() }
            log.add("Launch at login \(enable ? "enabled" : "disabled")")
        } catch {
            log.add("Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
        }
        refresh()
        if needsApproval {
            log.add("Launch at login needs approval in System Settings > General > Login Items", level: .warning)
        }
    }
}
