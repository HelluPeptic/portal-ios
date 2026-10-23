import UIKit

/// What pressing and holding the app icon offers: the Vault, Downloads,
/// the Dashboard, and the live panel (named for what tapping it will do).
/// Set from here rather than Info.plist so the live panel's can change.
enum QuickActions {
    static let vault = "org.hellupeptic.portal.vault"
    static let downloads = "org.hellupeptic.portal.downloads"
    static let dashboard = "org.hellupeptic.portal.dashboard"
    static let live = "org.hellupeptic.portal.live"

    static func update() {
        let running = LiveStats.shared.isRunning
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: vault, localizedTitle: "Vault", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "film"), userInfo: nil),
            UIApplicationShortcutItem(type: downloads, localizedTitle: "Downloads", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.circle"), userInfo: nil),
            UIApplicationShortcutItem(type: dashboard, localizedTitle: "Dashboard", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "gauge"), userInfo: nil),
            UIApplicationShortcutItem(type: live, localizedTitle: running ? "Stop live panel" : "Live panel",
                                      localizedSubtitle: running ? nil : "The Pi on the lock screen",
                                      icon: UIApplicationShortcutIcon(systemImageName: running ? "stop.circle" : "waveform.path.ecg"), userInfo: nil)
        ]
    }
}
