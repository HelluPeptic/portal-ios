import UIKit
import WebKit

/// Lets the site's Vault save movies and episodes in the app to watch
/// without a connection. The page calls
/// `window.webkit.messageHandlers.portalDownloads.postMessage({ cmd, ... })`,
/// which returns a promise with the reply (see the downloads part of
/// vault.js); it polls `list` while something downloads.
final class OfflineBridge: NSObject {
    static let shared = OfflineBridge()

    /// Set by WebViewController: the Downloads list, and playing one.
    var showList: (() -> Void)?
    var play: ((String) -> Void)?

    private func handle(_ cmd: String, _ body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let store = OfflineStore.shared
        let item = body["item"] as? String ?? ""
        switch cmd {
        case "list":
            var out: [String: Any] = [
                "items": store.items.map { entry -> [String: Any] in
                    ["item": entry.item, "state": entry.state.rawValue, "progress": entry.progress, "size": entry.size]
                },
                "device": UIDevice.current.model
            ]
            if let free = store.freeSpace { out["free"] = free }
            reply(out, nil)
        case "start":
            guard let info = body["download"] as? [String: Any] else {
                return reply(["ok": false, "message": "Nothing to download"], nil)
            }
            if let problem = store.start(info) {
                reply(["ok": false, "message": problem], nil)
            } else {
                reply(["ok": true], nil)
            }
        case "retry":
            store.retry(item, info: body["download"] as? [String: Any])
            reply(["ok": true], nil)
        case "remove":
            store.remove(item)
            reply(["ok": true], nil)
        case "open":
            showList?()
            reply(["ok": true], nil)
        case "play":
            play?(item)
            reply(["ok": true], nil)
        case "pendingProgress":
            reply(["items": store.pendingProgress()], nil)
        case "synced":
            store.synced(body["items"] as? [[String: Any]] ?? [])
            reply(["ok": true], nil)
        default:
            reply(nil, "Unknown command")
        }
    }
}

extension OfflineBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the site itself.
        guard message.frameInfo.securityOrigin.host == Portal.siteHost else {
            return replyHandler(nil, "Not allowed")
        }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        handle(cmd, body, reply: replyHandler)
    }
}
