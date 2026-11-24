import Foundation
import UserNotifications

/// Safe macOS notification sender that works both inside a bundled `.app` and when launched directly via `swift run`.
enum NotificationHelper {
    /// UserNotifications aborts outside a real `.app` (swift run, test hosts) even when a bundle ID exists.
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static func requestPermissionIfBundled() {
        guard isAppBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(title: String, body: String) {
        if isAppBundle {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Plain sound: critical alerts need a special entitlement this app does not have.
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        } else {
            // Safe AppleScript fallback for unbundled dev execution (passes strings via argv, zero injection risk)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = [
                "-e", "on run argv",
                "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e", "end run",
                "--", title, body
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
    }
}
