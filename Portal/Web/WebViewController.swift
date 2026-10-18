import UIKit
import WebKit
import SafariServices

/// The whole app is the site in a web view, plus what a browser tab can't
/// do: Chromecast casting (see CastBridge), native pop-ups for the site's
/// confirm()/prompt() dialogs, downloads to the share sheet, and a notice
/// before the free signature runs out.
final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let loadingBar = UIProgressView(progressViewStyle: .bar)
    private let banner = StatusBanner()
    private var errorView: UIView?
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [WKDownload: URL] = [:]
    private var downloadObservation: NSKeyValueObservation?

    private static let lastURLKey = "lastURL"

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .default() // keeps the site's login between launches
        // Keeps the usual "Mobile/..." token so the site still sees a phone.
        config.applicationNameForUserAgent = "Mobile/15E148 PortalApp/\(AppInfo.version)"
        config.userContentController.addScriptMessageHandler(CastBridge.shared, contentWorld: .page, name: "portalCast")
        let marker = WKUserScript(source: "window.PortalApp = { version: '\(AppInfo.version)', build: \(AppInfo.build) }; document.documentElement.classList.add('portal-app');",
                                  injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(marker)
        // Feels like an app rather than a web page: no pinch or double-tap
        // zoom (text fields are 16px on phones, so iOS doesn't zoom into them).
        let noZoom = WKUserScript(source: """
            (function () {
                function apply() {
                    var meta = document.querySelector('meta[name=viewport]');
                    if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; (document.head || document.documentElement).appendChild(meta); }
                    meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
                }
                if (document.head) apply(); else document.addEventListener('DOMContentLoaded', apply);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(noZoom)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Pages change from the site's own tab bar, not by swiping in from
        // the edge (that went back through every page and folder visited).
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .portalBackground
        webView.scrollView.backgroundColor = .portalBackground
        webView.underPageBackgroundColor = .portalBackground
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        let root = UIView()
        root.backgroundColor = .portalBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        loadingBar.translatesAutoresizingMaskIntoConstraints = false
        loadingBar.progressTintColor = .portalAccent
        loadingBar.trackTintColor = .clear
        loadingBar.alpha = 0
        root.addSubview(loadingBar)

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        root.addSubview(banner)

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safe.topAnchor),
            webView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            loadingBar.topAnchor.constraint(equalTo: safe.topAnchor),
            loadingBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),
            banner.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            banner.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.updateLoadingBar(Float(webView.estimatedProgress))
        })
        banner.onAction = { [weak self] in self?.bannerAction() }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        webView.load(URLRequest(url: startURL()))
        checkAppStatus()
    }

    // Reopens where you were last time, as long as that was on the site.
    private func startURL() -> URL {
        if let saved = UserDefaults.standard.string(forKey: Self.lastURLKey),
           let url = URL(string: saved), Portal.isSite(url), !url.path.hasPrefix("/login") {
            return url
        }
        return Portal.siteURL
    }

    @objc private func appDidEnterBackground() {
        if let url = webView.url, Portal.isSite(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
        }
        // A few extra seconds for whatever the page was in the middle of (a
        // chunk of an upload, a progress save) before iOS suspends the app.
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(task)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    @objc private func appWillEnterForeground() {
        checkAppStatus()
        if errorView != nil { retry() }
    }

    private func updateLoadingBar(_ progress: Float) {
        if progress >= 1 {
            loadingBar.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.25, delay: 0.15) { self.loadingBar.alpha = 0 } completion: { _ in
                self.loadingBar.setProgress(0, animated: false)
            }
        } else {
            loadingBar.alpha = 1
            loadingBar.setProgress(max(progress, 0.08), animated: true)
        }
    }

    // MARK: - Links that leave the site

    private func openOutside(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = .portalAccent
            safari.preferredBarTintColor = .portalBackground
            present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Can't reach the site

    private func showError(_ message: String) {
        guard errorView == nil else { return }
        let box = UIStackView()
        box.axis = .vertical
        box.alignment = .center
        box.spacing = 14
        box.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Can't reach the site"
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .portalText

        let detail = UILabel()
        detail.text = message
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .portalTextDim
        detail.numberOfLines = 0
        detail.textAlignment = .center

        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.title = "Try again"
        buttonConfig.baseBackgroundColor = .portalAccent
        buttonConfig.baseForegroundColor = UIColor(red: 0x1a / 255, green: 0x14 / 255, blue: 0x11 / 255, alpha: 1)
        buttonConfig.cornerStyle = .large
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 26, bottom: 12, trailing: 26)
        let button = UIButton(configuration: buttonConfig, primaryAction: UIAction { [weak self] _ in self?.retry() })

        [title, detail, button].forEach(box.addArrangedSubview)
        box.setCustomSpacing(24, after: detail)

        let overlay = UIView()
        overlay.backgroundColor = .portalBackground
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(box)
        view.insertSubview(overlay, belowSubview: banner)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            box.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 32),
            box.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -32)
        ])
        errorView = overlay
    }

    private func retry() {
        errorView?.removeFromSuperview()
        errorView = nil
        if webView.url == nil || !Portal.isSite(webView.url) {
            webView.load(URLRequest(url: startURL()))
        } else {
            webView.reload()
        }
    }

    // MARK: - Expiry and update notice

    private enum BannerKind { case expiry, update }
    private var bannerKind: BannerKind?
    private var offeredBuild = 0
    private static let dismissedUpdateKey = "dismissedUpdate"

    private func checkAppStatus() {
        if let expiry = AppInfo.expiryDate {
            let days = expiry.timeIntervalSinceNow / 86400
            if days < 2 {
                // Installed through SideStore it refreshes there; installed
                // straight from a computer (iloader) it gets installed again.
                let viaSideStore = UIApplication.shared.canOpenURL(Portal.sideStoreURL)
                let text = viaSideStore
                    ? "Portal needs a refresh in SideStore \(days < 1 ? "today" : "within 2 days")."
                    : "Portal stops opening \(days < 1 ? "within a day" : "in under 2 days"). Install it again from your computer to keep it."
                showBanner(.expiry, text: text, button: viaSideStore ? "Open SideStore" : "How")
                return
            }
        }
        var request = URLRequest(url: Portal.appInfoURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = (info["build"] as? NSNumber)?.intValue,
                  latest > AppInfo.build,
                  UserDefaults.standard.integer(forKey: Self.dismissedUpdateKey) != latest else { return }
            DispatchQueue.main.async {
                self?.offeredBuild = latest
                self?.showBanner(.update, text: "A new version of Portal is ready.", button: "Update")
            }
        }.resume()
    }

    private func showBanner(_ kind: BannerKind, text: String, button: String) {
        bannerKind = kind
        banner.configure(text: text, button: button)
        banner.onClose = { [weak self] in
            guard let self else { return }
            self.hideBanner()
            // Don't nag about the same version again.
            if kind == .update { UserDefaults.standard.set(self.offeredBuild, forKey: Self.dismissedUpdateKey) }
        }
        guard banner.isHidden else { return }
        banner.alpha = 0
        banner.isHidden = false
        UIView.animate(withDuration: 0.25) { self.banner.alpha = 1 }
    }

    private func hideBanner() {
        UIView.animate(withDuration: 0.2) { self.banner.alpha = 0 } completion: { _ in self.banner.isHidden = true }
    }

    private func bannerAction() {
        if UIApplication.shared.canOpenURL(Portal.sideStoreURL) {
            UIApplication.shared.open(Portal.sideStoreURL)
        } else {
            openOutside(Portal.appPageURL)
        }
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https":
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            // The site itself, and anything loading inside one of its frames,
            // stays here; other sites the person taps through to open on top.
            if Portal.isSite(url) || !isMainFrame || navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                openOutside(url)
                decisionHandler(.cancel)
            }
        case "about", "blob", "data":
            decisionHandler(.allow)
        default:
            // mailto:, tel:, sidestore:, App Store links...
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView?.removeFromSuperview()
        errorView = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let nsError = error as NSError
        // Cancelled (another load started) or turned into a download: not a failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        if nsError.domain == NSURLErrorDomain {
            showError("Check that you're online, then try again.")
        }
    }

    // The page's process can be killed in the background (memory); bring it back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Pop-ups and new windows

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" / window.open: the site opens here, anything else on top.
        if let url = navigationAction.request.url {
            if Portal.isSite(url) { webView.load(navigationAction.request) } else { openOutside(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentAlert(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentAlert(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.clearButtonMode = .whileEditing
            // The TV code is digits only.
            if prompt.lowercased().contains("code") { field.keyboardType = .numberPad }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presentAlert(alert) { completionHandler(nil) }
    }

    /// WebKit insists every panel's completion handler is called exactly
    /// once, even if the alert can't be shown (something else is on screen).
    private func presentAlert(_ alert: UIAlertController, orElse fallback: @escaping () -> Void) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        guard top.viewIfLoaded?.window != nil, !(top is UIAlertController) else { return fallback() }
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Portal.siteHost ? .grant : .prompt)
    }
}

// MARK: - Downloads

extension WebViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        try? FileManager.default.removeItem(at: destination)
        downloads[download] = destination
        loadingBar.alpha = 1
        downloadObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.loadingBar.setProgress(Float(progress.fractionCompleted), animated: true) }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadObservation = nil
        updateLoadingBar(1)
        guard let file = downloads.removeValue(forKey: download) else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadObservation = nil
        updateLoadingBar(1)
        downloads.removeValue(forKey: download)
        let alert = UIAlertController(title: "Download failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert) {}
    }
}
