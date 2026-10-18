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
        return true
    }

    /// On a phone the app stays upright. Full-screen video gets a window of
    /// its own from WebKit (or is presented over the page), and that can turn
    /// sideways, so movies still play in landscape.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        guard let page = window?.rootViewController as? WebViewController else { return .allButUpsideDown }
        if let presented = page.presentedViewController,
           presented is AVPlayerViewController || String(describing: type(of: presented)).contains("FullScreen") {
            return .allButUpsideDown
        }
        return .portrait
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
