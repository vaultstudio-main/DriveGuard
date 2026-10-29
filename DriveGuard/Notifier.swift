//
//  Notifier.swift
//  DriveGuard
//

import Foundation
import UserNotifications

/// Posts user notifications for failures. Shows banners even while the app is frontmost.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard AppSettings.shared.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
