import Foundation
import WebKit
import WidgetKit

/// Connects the home screen widget (PortalWidget) to the site: a logged-in
/// page hands over the widget's own token (spa-shell.js asks for one from
/// /api/widget/token), which goes in the app group the widget reads.
/// `window.webkit.messageHandlers.portalWidget.postMessage({ cmd, ... })`.
final class WidgetBridge: NSObject {
    static let shared = WidgetBridge()

    /// Has the widget fetch fresh numbers. Called on leaving the app, so the
    /// home screen shows them straight away (iOS allows extra refreshes
    /// while the app is still in front).
    static func refresh() {
        guard SharedStore.token != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.host == Portal.siteHost else {
            return replyHandler(nil, "Not allowed")
        }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        switch cmd {
        case "status":
            // No app group (SideStore left it out): nothing to connect.
            replyHandler(["connected": SharedStore.defaults == nil || SharedStore.token != nil], nil)
        case "connect":
            guard let token = body["token"] as? String, !token.isEmpty, SharedStore.defaults != nil else {
                return replyHandler(["ok": false], nil)
            }
            SharedStore.token = token
            WidgetCenter.shared.reloadAllTimelines()
            replyHandler(["ok": true], nil)
        default:
            replyHandler(nil, "Unknown command")
        }
    }
}
