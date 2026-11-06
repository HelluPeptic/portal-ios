import Foundation
import WebKit

/// The Vault player's full screen (vault.js setAppFull): the app turns
/// sideways, either way round so the phone can be flipped over, and hides
/// the clock, battery and home bar until the player says it's done.
/// `window.webkit.messageHandlers.portalScreen.postMessage({ cmd: 'fullscreen', on })`.
/// WebKit's own full screen isn't used for this: on a phone it froze the
/// player and left a grey screen behind when it ended.
final class ScreenBridge: NSObject {
    static let shared = ScreenBridge()

    /// WebViewController.setPlayerFullScreen.
    var setFullScreen: ((Bool) -> Void)?
}

extension ScreenBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.host == Portal.siteHost else {
            return replyHandler(nil, "Not allowed")
        }
        guard let body = message.body as? [String: Any], body["cmd"] as? String == "fullscreen" else {
            return replyHandler(nil, "Bad message")
        }
        let on = (body["on"] as? Bool) ?? false
        setFullScreen?(on)
        replyHandler(["ok": true], nil)
    }
}
