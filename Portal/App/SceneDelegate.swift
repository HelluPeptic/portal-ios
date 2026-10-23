import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .portalBackground
        window.tintColor = .portalAccent
        let page = WebViewController()
        window.rootViewController = page
        window.makeKeyAndVisible()
        self.window = window
        // Opened from a pepticworkshop:// link, or the icon's quick actions.
        if let url = connectionOptions.urlContexts.first?.url {
            DispatchQueue.main.async { page.open(url) }
        }
        if let shortcut = connectionOptions.shortcutItem {
            DispatchQueue.main.async { page.perform(shortcut) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let page = window?.rootViewController as? WebViewController else { return completionHandler(false) }
        page.perform(shortcutItem)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url, let page = window?.rootViewController as? WebViewController else { return }
        page.open(url)
    }
}
