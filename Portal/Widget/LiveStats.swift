import ActivityKit
import UIKit
import WebKit
#if canImport(notify)
import notify
#endif

/// The live panel: the Pi's numbers on the lock screen and in the Dynamic
/// Island (a Live Activity, drawn by LivePanel in the widget), every 5
/// seconds while it's on. Started and stopped from the Dashboard
/// (LiveBridge below). Only a server with a paid developer account can
/// update one while the app sleeps, so the app does it itself, kept awake in
/// the background by KeepAlive. That costs battery, so it asks once a minute
/// while the screen is off (and at once when it comes on), and it stops
/// when swiped away on the lock screen. iOS ends any Live Activity after 8
/// hours.
final class LiveStats {
    static let shared = LiveStats()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The widgets' token for the site, handed over by the Dashboard; kept
    /// so a panel left on carries on after the app is opened again.
    private static let tokenKey = "liveToken"
    private var activity: Activity<PiActivityAttributes>?
    private var loop: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var lastGood: PiActivityAttributes.ContentState?
    private var screenOff = false
    private var screenToken: Int32 = 0

    var isRunning: Bool { activity != nil }

    /// Why it can't start, if it can't.
    var unavailableReason: String? {
        let widget = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PortalWidget.appex").path
        if widget.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            return "It needs the widget, which was left out when installing. Install again from SideStore and pick Use Main Profile."
        }
        if !ActivityAuthorizationInfo().areActivitiesEnabled {
            return "Live Activities are off for this app. Turn them on in Settings, under Peptic's Workshop."
        }
        return nil
    }

    private init() {
        let center = NotificationCenter.default
        // The sound has to start while the app is still in front.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leaving()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.back()
        }
        watchScreen()
    }

    /// At launch: a panel left on when the app was last closed carries on.
    @MainActor func resume() {
        let running = Activity<PiActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        guard let first = running.first, UserDefaults.standard.string(forKey: Self.tokenKey) != nil else {
            for old in running { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        for extra in running.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        attach(first)
    }

    @MainActor func start(token: String) async throws {
        if let reason = unavailableReason { throw Failure(message: reason) }
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        guard activity == nil else { return }
        // Its first numbers before it shows, so it never shows up empty.
        let first: PiActivityAttributes.ContentState
        do {
            first = .init(try await LiveReading.fetch(token: token))
        } catch {
            throw Failure(message: "The Pi didn't answer. Try again in a moment.")
        }
        lastGood = first
        let started = try Activity.request(attributes: PiActivityAttributes(),
                                           content: ActivityContent(state: first, staleDate: Date().addingTimeInterval(30)),
                                           pushType: nil)
        attach(started)
    }

    @MainActor func stop() async {
        guard let current = activity else { return }
        watcher?.cancel()
        ended(current)
        await current.end(nil, dismissalPolicy: .immediate)
    }

    @MainActor private func attach(_ started: Activity<PiActivityAttributes>) {
        activity = started
        watcher?.cancel()
        // Swiped away on the lock screen, or ended by iOS after 8 hours.
        watcher = Task { @MainActor [weak self] in
            for await state in started.activityStateUpdates where state == .dismissed || state == .ended {
                self?.ended(started)
                break
            }
        }
        runLoop()
    }

    @MainActor private func ended(_ which: Activity<PiActivityAttributes>) {
        guard activity?.id == which.id else { return }
        activity = nil
        loop?.cancel()
        loop = nil
        watcher = nil
        lastGood = nil
        KeepAlive.shared.release("live")
    }

    /// Asks every 5 seconds (once a minute with the screen off), starting now.
    private func runLoop() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let seconds: UInt64 = self?.screenOff == true ? 60 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    @MainActor private func tick() async {
        guard let current = activity, let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        let state: PiActivityAttributes.ContentState
        do {
            state = .init(try await LiveReading.fetch(token: token))
            lastGood = state
        } catch ServerStats.FetchError.rejected {
            // The site's token was made again: it's started again from the
            // Dashboard, which hands over the new one.
            await stop()
            return
        } catch ServerStats.FetchError.server(_) {
            // An answer, just not from the Pi (Cloudflare, nginx).
            state = known(current, .serverDown)
        } catch {
            if Task.isCancelled { return }
            // No answer at all: the Pi, or this phone's connection?
            state = known(current, await ServerStats.internetReachable() ? .serverDown : .noInternet)
        }
        guard activity?.id == current.id else { return }
        // Shown as not updating if the app stops (iOS ended it, say).
        let staleDate = Date().addingTimeInterval(screenOff ? 150 : 30)
        await current.update(ActivityContent(state: state, staleDate: staleDate))
    }

    /// The last numbers the Pi gave, with why there are no newer ones.
    private func known(_ current: Activity<PiActivityAttributes>, _ status: PiActivityAttributes.ContentState.Status) -> PiActivityAttributes.ContentState {
        var state = lastGood ?? current.content.state
        state.status = status
        return state
    }

    private func leaving() {
        guard activity != nil else { return }
        KeepAlive.shared.hold("live")
    }

    private func back() {
        KeepAlive.shared.release("live")
        if activity != nil { runLoop() }
    }

    /// Whether the screen is off (iOS tells anyone listening), to ask less
    /// often meanwhile.
    private func watchScreen() {
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &screenToken, .main) { [weak self] token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            guard let self, (state != 0) != self.screenOff else { return }
            self.screenOff = state != 0
            // Fresh numbers the moment it comes on.
            if !self.screenOff, self.activity != nil { self.runLoop() }
        }
    }
}

/// The Dashboard's "Show live on lock screen" button (dashboard.js):
/// `window.webkit.messageHandlers.portalLive.postMessage({ cmd, ... })`.
final class LiveBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = LiveBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.host == Portal.siteHost else {
            return replyHandler(nil, "Not allowed")
        }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        let token = body["token"] as? String
        Task { @MainActor in
            let live = LiveStats.shared
            switch cmd {
            case "status":
                var reply: [String: Any] = ["running": live.isRunning]
                if let reason = live.unavailableReason { reply["reason"] = reason }
                replyHandler(reply, nil)
            case "start":
                guard let token, !token.isEmpty else { return replyHandler(["ok": false], nil) }
                do {
                    try await live.start(token: token)
                    replyHandler(["ok": true], nil)
                } catch {
                    replyHandler(["ok": false, "error": error.localizedDescription], nil)
                }
            case "stop":
                await live.stop()
                replyHandler(["ok": true], nil)
            default:
                replyHandler(nil, "Unknown command")
            }
        }
    }
}
