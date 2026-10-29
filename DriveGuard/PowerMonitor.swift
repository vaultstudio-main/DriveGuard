//
//  PowerMonitor.swift
//  DriveGuard
//

import Foundation
import IOKit
import IOKit.pwr_mgt

/// Observes system sleep/wake through IORegisterForSystemPower so we can hold sleep briefly.
///
/// Rules this class enforces: it never vetoes sleep, and every will-sleep message is acknowledged
/// exactly once through the `allow` closure handed to the handler.
@MainActor
final class PowerMonitor {
    // IOKit message constants are C macros Swift can't import.
    fileprivate static let canSystemSleep: UInt32 = 0xE000_0270
    fileprivate static let systemWillSleep: UInt32 = 0xE000_0280
    fileprivate static let systemHasPoweredOn: UInt32 = 0xE000_0300

    var onWillSleep: (_ allow: @escaping () -> Void) -> Void = { $0() }
    var onDidWake: () -> Void = {}

    fileprivate var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    func start() {
        guard rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, powerCallback, &notifier)
        guard rootPort != 0, let notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                           .commonModes)
    }

    fileprivate func handle(_ message: UInt32, argument: Int) {
        let port = rootPort
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(port, argument) // never veto
        case Self.systemWillSleep:
            onWillSleep { IOAllowPowerChange(port, argument) }
        case Self.systemHasPoweredOn:
            onDidWake()
        default:
            break
        }
    }
}

private nonisolated func powerCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let argument = Int(bitPattern: messageArgument)
    // Registered on the main run loop, so this always runs on the main thread.
    MainActor.assumeIsolated {
        Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument: argument)
    }
}
