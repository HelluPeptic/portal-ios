import UIKit
import WebKit

/// Plays a download in the app's own copy of the site's Vault player
/// (Resources/offline-player.html: the picture fills the screen and the
/// controls lie over it), straight from the file on the phone, so it works
/// with no connection and never in Apple's player. Where it got to is saved
/// as it plays, for the site (OfflineStore's pendingProgress).
enum OfflinePlayback {
    /// Called once a player closes (WebViewController hands the site where
    /// it was left).
    static var onClose: (() -> Void)?

    static func play(_ item: String, from presenter: UIViewController) {
        guard let entry = OfflineStore.shared.items.first(where: { $0.item == item && $0.state == .done }),
              let page = OfflineStore.shared.playerPage() else { return }
        presenter.present(OfflinePlayerController(entry, page: page), animated: true)
    }
}

/// The player page over the whole screen, upright or sideways. The page
/// says what happens through the "offlinePlayer" message handler:
/// position, subtitle, rotate and close.
final class OfflinePlayerController: UIViewController {
    private let entry: OfflineItem
    private let page: URL
    private let webView: WKWebView
    /// The page's subtitle lines are the ones whose files are here; these
    /// are their places in the download's own list.
    private var subtitleIndexes: [Int] = []
    /// Upright and sideways by hand; only sideways once "full screen" turned
    /// it, so it stays that way until it's pressed again.
    private var turns: UIInterfaceOrientationMask = .allButUpsideDown
    private var finished = false

    init(_ entry: OfflineItem, page: URL) {
        self.entry = entry
        self.page = page
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        config.userContentController.add(MessageRelay(self), name: "offlinePlayer")
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { turns }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        NotificationCenter.default.addObserver(self, selector: #selector(save), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    /// What the page needs: the files are relative to it (Offline/<id>/...).
    private func start() {
        let store = OfflineStore.shared
        var subtitles: [[String: Any]] = []
        subtitleIndexes = []
        for (index, sub) in entry.subtitles.enumerated() {
            let file = store.subtitleFile(entry, index)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            subtitleIndexes.append(index)
            subtitles.append(["label": sub.label, "lang": sub.lang ?? "", "src": "\(entry.id)/\(file.lastPathComponent)"])
        }
        var chosen: Any = NSNull()
        if let index = entry.subtitle, let line = subtitleIndexes.firstIndex(of: index) { chosen = line }
        let config: [String: Any] = [
            "title": entry.title,
            "detail": entry.detail,
            "video": "\(entry.id)/\(store.videoFile(entry).lastPathComponent)",
            "subtitles": subtitles,
            "subtitle": chosen,
            // From where it was left, unless it was watched to the end.
            "resumeAt": entry.position > 10 && entry.position < entry.watchedFrom ? entry.position : 0
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.startPlayer(\(json))", completionHandler: nil)
    }

    fileprivate func received(_ body: [String: Any]) {
        switch body["cmd"] as? String {
        case "position":
            let time = (body["time"] as? NSNumber)?.doubleValue ?? 0
            let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
            OfflineStore.shared.setPosition(entry.item, time, duration: duration)
        case "subtitle":
            let line = (body["index"] as? NSNumber)?.intValue
            OfflineStore.shared.setSubtitle(entry.item, line.flatMap { $0 >= 0 && $0 < subtitleIndexes.count ? subtitleIndexes[$0] : nil })
        case "rotate":
            rotate()
        case "close":
            close()
        default:
            break
        }
    }

    /// Full screen: sideways, or back upright.
    private func rotate() {
        guard let scene = view.window?.windowScene else { return }
        let sideways = scene.interfaceOrientation.isLandscape
        turns = sideways ? .allButUpsideDown : .landscape
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: sideways ? .portrait : .landscapeRight)) { _ in }
    }

    private func close() {
        finish()
        turns = .portrait
        setNeedsUpdateOfSupportedInterfaceOrientations()
        dismiss(animated: true)
    }

    @objc private func save() {
        webView.evaluateJavaScript("window.savePosition && window.savePosition()", completionHandler: nil)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "offlinePlayer")
        OfflinePlayback.onClose?()
    }
}

extension OfflinePlayerController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        start()
    }

    // Only the page itself; nothing else opens in here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// The content controller keeps its handlers, so this passes messages on
/// without keeping the player.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var player: OfflinePlayerController?

    init(_ player: OfflinePlayerController) {
        self.player = player
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        player?.received(body)
    }
}
