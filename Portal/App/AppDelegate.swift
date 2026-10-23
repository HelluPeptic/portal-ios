import UIKit
import AVFoundation
import AVKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Videos played in the app keep their sound with the ring/silent
        // switch on, like in any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        CastBridge.configure()
        // A live panel left on last time carries on.
        LiveStats.shared.resume()
        // Picks up downloads that went on while the app was closed.
        _ = OfflineStore.shared
        return true
    }

    /// Downloads finished (or need attention) while the app was in the
    /// background: iOS wakes it to hear about them.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineStore.sessionIdentifier else { return completionHandler() }
        OfflineStore.shared.backgroundCompletion = completionHandler
    }

    /// On a phone the app stays upright. Full-screen video gets a window of
    /// its own from WebKit (or is presented over the page, or over the
    /// Downloads list), and that can turn sideways, so movies still play in
    /// landscape.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        guard let page = window?.rootViewController as? WebViewController else { return .allButUpsideDown }
        var presented = page.presentedViewController
        while let shown = presented {
            if shown is AVPlayerViewController || String(describing: type(of: shown)).contains("FullScreen") {
                return .allButUpsideDown
            }
            presented = shown.presentedViewController
        }
        return .portrait
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
