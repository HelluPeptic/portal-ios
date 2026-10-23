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
        // Opened from a pepticworkshop:// link.
        if let url = connectionOptions.urlContexts.first?.url {
            DispatchQueue.main.async { page.open(url) }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url, let page = window?.rootViewController as? WebViewController else { return }
        page.open(url)
    }
}
