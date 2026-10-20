import UIKit
import WebKit
import GoogleCast

/// Lets the site's Vault player use Google's Cast SDK. The page calls
/// `window.webkit.messageHandlers.portalCast.postMessage({ cmd, ... })`,
/// which returns a promise with the reply, and polls `status` while it shows
/// its remote controls (see the "Chromecasts, inside the iPhone app" part of
/// vault.js). Chromecasts play the Default Media Receiver, fed with tokened
/// links from the site, so nothing here needs a login.
final class CastBridge: NSObject {
    static let shared = CastBridge()

    static func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // The phone's volume buttons turn the TV up and down while casting.
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // The site's TV menu starts discovery when it opens (and that's when
        // iOS asks for Local Network access), not app launch.
        options.disableDiscoveryAutostart = true
        options.startDiscoveryAfterFirstTapOnCastButton = false
        // Stays connected while the app is in the background instead of
        // letting go of the TV and picking it back up later: a Chromecast
        // left with no phone connected throws away a paused video.
        // CastKeepAlive keeps the app running meanwhile.
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKLogger.sharedInstance().loggingEnabled = false
        GCKCastContext.sharedInstance().sessionManager.add(shared)
        shared.watchAppState()
    }

    private var context: GCKCastContext { GCKCastContext.sharedInstance() }
    private var session: GCKCastSession? { context.sessionManager.currentCastSession }
    private var client: GCKRemoteMediaClient? { session?.remoteMediaClient }

    /// A "start" waiting for its session to connect, to load something or
    /// (with no media) just to be connected.
    private var pendingStart: (body: [String: Any], reply: Reply)?
    private var requestCallbacks: [Int: (Bool, String?) -> Void] = [:]

    typealias Reply = (Any?, String?) -> Void

    // MARK: - Commands

    private func handle(_ cmd: String, _ body: [String: Any], reply: @escaping Reply) {
        switch cmd {
        case "devices":
            startDiscovery()
            reply(["devices": deviceList()], nil)
        case "stopDiscovery":
            // Kept going while connected or reconnecting: the Cast SDK only
            // gets a dropped connection back once it sees the TV again.
            if session == nil, pendingStart == nil, context.sessionManager.connectionState == .disconnected {
                context.discoveryManager.stopDiscovery()
            }
            reply(["ok": true], nil)
        case "start":
            start(body, reply: reply)
        case "load":
            load(body, reply: reply)
        case "append":
            append(body, reply: reply)
        case "status":
            reply(status(), nil)
        case "play":
            withClient(reply) { $0.play() }
        case "pause":
            withClient(reply) { $0.pause() }
        case "seek":
            let options = GCKMediaSeekOptions()
            options.interval = (body["time"] as? NSNumber)?.doubleValue ?? 0
            options.resumeState = .unchanged
            withClient(reply) { $0.seek(with: options) }
        case "tracks":
            let ids = (body["ids"] as? [NSNumber]) ?? []
            withClient(reply) { $0.setActiveTrackIDs(ids) }
        case "volume":
            guard let session else { return reply(notConnected, nil) }
            let level = (body["level"] as? NSNumber)?.floatValue ?? 1
            track(session.setDeviceVolume(max(0, min(1, level))), reply: reply)
        case "mute":
            guard let session else { return reply(notConnected, nil) }
            track(session.setDeviceMuted((body["muted"] as? Bool) ?? false), reply: reply)
        case "stopMedia":
            // Stops what's playing but stays connected, ready for the next thing.
            withClient(reply) { $0.stop() }
        case "stop":
            UserDefaults.standard.removeObject(forKey: Self.castingKey)
            context.sessionManager.endSessionAndStopCasting(true)
            reply(["ok": true], nil)
        default:
            reply(nil, "Unknown command")
        }
    }

    private var notConnected: [String: Any] {
        ["ok": false, "error": "connect", "message": "Not connected to a TV"]
    }

    // MARK: - Discovery

    private func startDiscovery() {
        let discovery = context.discoveryManager
        discovery.passiveScan = false
        discovery.startDiscovery()
    }

    private func deviceList() -> [[String: Any]] {
        let discovery = context.discoveryManager
        var devices: [[String: Any]] = []
        for index in 0..<discovery.deviceCount {
            let device = discovery.device(at: index)
            // Speaker groups and audio-only speakers can't show a video.
            guard device.hasCapabilities(.videoOut) else { continue }
            devices.append([
                "id": device.deviceID,
                "name": device.friendlyName ?? "Chromecast",
                "model": device.modelName ?? ""
            ])
        }
        return devices.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func findDevice(_ id: String) -> GCKDevice? {
        let discovery = context.discoveryManager
        for index in 0..<discovery.deviceCount where discovery.device(at: index).deviceID == id {
            return discovery.device(at: index)
        }
        return nil
    }

    // MARK: - Sessions and loading

    private func start(_ body: [String: Any], reply: @escaping Reply) {
        guard let deviceId = body["deviceId"] as? String, let device = findDevice(deviceId) else {
            return reply(["ok": false, "error": "connect", "message": "That TV isn't on this Wi-Fi any more"], nil)
        }
        if let session, session.device.deviceID == deviceId, session.connectionState == .connected {
            return body["media"] == nil ? reply(["ok": true], nil) : load(body, reply: reply)
        }
        pendingStart?.reply(["ok": false, "error": "replaced", "message": "Started something else"], nil)
        pendingStart = (body, reply)
        // Switching TVs ends the current session first; the SDK handles that.
        guard context.sessionManager.startSession(with: device) else {
            pendingStart = nil
            return reply(["ok": false, "error": "connect", "message": "Could not connect to the TV"], nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, let pending = self.pendingStart, (pending.body["deviceId"] as? String) == deviceId else { return }
            self.pendingStart = nil
            pending.reply(["ok": false, "error": "connect", "message": "The TV didn't answer"], nil)
        }
    }

    private func load(_ body: [String: Any], reply: @escaping Reply) {
        guard let client else { return reply(notConnected, nil) }
        guard let media = body["media"] as? [String: Any], let info = mediaInformation(from: media) else {
            return reply(["ok": false, "error": "bad", "message": "Nothing to play"], nil)
        }
        let builder = GCKMediaLoadRequestDataBuilder()
        builder.mediaInformation = info
        builder.autoplay = NSNumber(value: true)
        builder.startTime = (body["startTime"] as? NSNumber)?.doubleValue ?? 0
        if let trackId = body["activeTrackId"] as? NSNumber { builder.activeTrackIDs = [trackId] }
        // A failed load means the Chromecast can't decode it ("error": "load"),
        // which tells the page to send the converted version instead.
        track(client.loadMedia(with: builder.build()), done: { ok, message in
            reply(ok ? ["ok": true] : ["ok": false, "error": "load", "message": message ?? "The TV could not play this video"], nil)
        })
    }

    /// Adds the next episodes to the Chromecast's own queue, so it moves on
    /// by itself even while the phone is locked.
    private func append(_ body: [String: Any], reply: @escaping Reply) {
        guard let client else { return reply(notConnected, nil) }
        let items: [GCKMediaQueueItem] = ((body["media"] as? [[String: Any]]) ?? []).compactMap { media in
            guard let info = mediaInformation(from: media) else { return nil }
            let builder = GCKMediaQueueItemBuilder()
            builder.mediaInformation = info
            builder.autoplay = true
            builder.preloadTime = 10
            return builder.build()
        }
        guard !items.isEmpty else { return reply(["ok": true], nil) }
        track(client.queueInsert(items, beforeItemWithID: kGCKMediaQueueInvalidItemID), reply: reply)
    }

    private func absolute(_ path: Any?) -> URL? {
        guard let path = path as? String else { return nil }
        return URL(string: path, relativeTo: Portal.siteURL)?.absoluteURL
    }

    /// Builds what the Chromecast plays from the link the site made
    /// (/api/cast/link). The whole link goes along as customData so `status`
    /// can tell the page which video and subtitles are on the TV.
    private func mediaInformation(from media: [String: Any]) -> GCKMediaInformation? {
        guard let url = absolute(media["url"]) else { return nil }
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.contentID = url.absoluteString
        builder.streamType = .buffered
        builder.contentType = media["contentType"] as? String ?? "video/mp4"
        if let duration = media["duration"] as? NSNumber { builder.streamDuration = duration.doubleValue }

        let isEpisode = (media["kind"] as? String) == "episode"
        let metadata = GCKMediaMetadata(metadataType: isEpisode ? .tvShow : .movie)
        if let title = media["title"] as? String { metadata.setString(title, forKey: kGCKMetadataKeyTitle) }
        if let series = media["seriesTitle"] as? String { metadata.setString(series, forKey: kGCKMetadataKeySeriesTitle) }
        if let season = media["season"] as? NSNumber { metadata.setInteger(season.intValue, forKey: kGCKMetadataKeySeasonNumber) }
        if let year = media["year"] as? String { metadata.setString(year, forKey: kGCKMetadataKeySubtitle) }
        if let image = absolute(media["image"]) { metadata.addImage(GCKImage(url: image, width: 600, height: 900)) }
        builder.metadata = metadata

        let tracks = (media["tracks"] as? [[String: Any]]) ?? []
        builder.mediaTracks = tracks.compactMap { track in
            guard let id = (track["id"] as? NSNumber)?.intValue, let trackURL = absolute(track["url"]) else { return nil }
            return GCKMediaTrack(identifier: id,
                                 contentIdentifier: trackURL.absoluteString,
                                 contentType: "text/vtt",
                                 type: .text,
                                 textSubtype: .subtitles,
                                 name: track["name"] as? String,
                                 languageCode: track["lang"] as? String,
                                 customData: nil)
        }
        if !tracks.isEmpty {
            let style = GCKMediaTextTrackStyle.createDefault()
            style.backgroundColor = GCKColor(cssString: "#00000000")
            style.foregroundColor = GCKColor(cssString: "#FFFFFFFF")
            style.edgeType = .outline
            style.edgeColor = GCKColor(cssString: "#000000FF")
            builder.textTrackStyle = style
        }
        if (media["hls"] as? Bool) == true {
            builder.hlsSegmentFormat = .TS
            builder.hlsVideoSegmentFormat = .MPEG2_TS
        }
        builder.customData = media
        return builder.build()
    }

    // MARK: - Status

    /// What this build supports, so the site can tell old builds from new.
    private static let features = ["connect"]

    private func status() -> [String: Any] {
        guard let session, session.connectionState == .connected else { return ["connected": false, "features": Self.features] }
        var out: [String: Any] = [
            "connected": true,
            "features": Self.features,
            "deviceId": session.device.deviceID,
            "deviceName": session.device.friendlyName ?? "Chromecast",
            "volume": session.currentDeviceVolume,
            "muted": session.currentDeviceMuted
        ]
        guard let client = session.remoteMediaClient, let status = client.mediaStatus else {
            out["state"] = "LOADING"
            return out
        }
        out["state"] = stateName(status.playerState)
        out["idleReason"] = idleReasonName(status.idleReason)
        let position = client.approximateStreamPosition()
        out["currentTime"] = position.isFinite ? position : 0
        if let info = status.mediaInformation {
            out["duration"] = info.streamDuration.isFinite ? info.streamDuration : 0
            if let custom = info.customData { out["media"] = custom }
        }
        out["activeTrackIds"] = status.activeTrackIDs ?? []
        out["queue"] = ["index": status.queueIndex(forItemID: status.currentItemID), "count": status.queueItemCount]
        return out
    }

    private func stateName(_ state: GCKMediaPlayerState) -> String {
        switch state {
        case .playing: return "PLAYING"
        case .paused: return "PAUSED"
        case .buffering: return "BUFFERING"
        case .loading: return "LOADING"
        case .idle: return "IDLE"
        default: return "LOADING"
        }
    }

    private func idleReasonName(_ reason: GCKMediaPlayerIdleReason) -> String? {
        switch reason {
        case .finished: return "FINISHED"
        case .cancelled: return "CANCELLED"
        case .interrupted: return "INTERRUPTED"
        case .error: return "ERROR"
        default: return nil
        }
    }

    // MARK: - Leaving the app

    private let keepAlive = CastKeepAlive()
    private var keepAliveTimer: Timer?
    private var pausedSince: Date?
    private var idleChecks = 0
    /// The TV this phone is casting to, kept across launches.
    private static let castingKey = "castingDeviceId"

    private func watchAppState() {
        let center = NotificationCenter.default
        // Resigning active comes first (and also covers locking the phone);
        // the sound has to start while the app is still in front.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.leaving() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.back()
        }
        // The app was closed or ended by iOS while casting: the Cast SDK
        // reconnects to that TV once discovery sees it.
        if UserDefaults.standard.string(forKey: Self.castingKey) != nil { startDiscovery() }
    }

    /// A video is on the TV: playing, paused or about to play. Not the
    /// picture the site shows there while nothing plays.
    private var videoOnTV: Bool {
        guard let session, session.connectionState == .connected, let status = client?.mediaStatus else { return false }
        if showingPicture(status) { return false }
        let state = status.playerState
        return state == .playing || state == .paused || state == .buffering || state == .loading
    }

    private func showingPicture(_ status: GCKMediaStatus) -> Bool {
        let type: String? = status.mediaInformation?.contentType
        return type?.hasPrefix("image/") ?? false
    }

    private func leaving() {
        guard videoOnTV, !keepAlive.isRunning else { return }
        keepAlive.start()
        guard keepAlive.isRunning else { return }
        pausedSince = nil
        idleChecks = 0
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkKeepAlive()
        }
    }

    /// Lets the app be frozen once there's nothing left to stay connected
    /// for: the video ended or was stopped, the TV went, or it has been
    /// paused for half an hour (a Chromecast gives up on a paused video
    /// after 20 minutes anyway).
    private func checkKeepAlive() {
        let status = session?.connectionState == .connected ? client?.mediaStatus : nil
        let state = status.flatMap { showingPicture($0) ? nil : $0.playerState }
        if state == .playing || state == .buffering || state == .loading {
            pausedSince = nil
            idleChecks = 0
            return
        }
        if state == .paused {
            idleChecks = 0
            let since = pausedSince ?? Date()
            pausedSince = since
            if Date().timeIntervalSince(since) < 30 * 60 { return }
        } else {
            // It's idle for a moment between two episodes.
            idleChecks += 1
            if idleChecks < 3 { return }
        }
        stopKeepAlive()
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pausedSince = nil
        keepAlive.stop()
    }

    private func back() {
        stopKeepAlive()
        // If the connection went while away, the Cast SDK picks it back up
        // once it sees the TV again, so look for it.
        if session != nil || UserDefaults.standard.string(forKey: Self.castingKey) != nil {
            startDiscovery()
        }
    }

    // MARK: - Requests

    private func withClient(_ reply: @escaping Reply, _ action: (GCKRemoteMediaClient) -> GCKRequest) {
        guard let client else { return reply(notConnected, nil) }
        track(action(client), reply: reply)
    }

    private func track(_ request: GCKRequest, reply: @escaping Reply) {
        track(request, done: { ok, message in
            reply(ok ? ["ok": true] : ["ok": false, "message": message ?? "The TV did not respond"], nil)
        })
    }

    private func track(_ request: GCKRequest, done: @escaping (Bool, String?) -> Void) {
        request.delegate = self
        requestCallbacks[request.requestID] = done
    }
}

// MARK: - From the page

extension CastBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the site itself gets to drive the TV.
        guard message.frameInfo.securityOrigin.host == Portal.siteHost else {
            return replyHandler(nil, "Not allowed")
        }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        handle(cmd, body, reply: replyHandler)
    }
}

// MARK: - Cast SDK callbacks

extension CastBridge: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        UserDefaults.standard.set(session.device.deviceID, forKey: Self.castingKey)
        guard let pending = pendingStart else { return }
        pendingStart = nil
        // Just connecting: the TV shows its Cast screen until something plays.
        if pending.body["media"] == nil { return pending.reply(["ok": true], nil) }
        load(pending.body, reply: pending.reply)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKCastSession) {
        UserDefaults.standard.set(session.device.deviceID, forKey: Self.castingKey)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        UserDefaults.standard.removeObject(forKey: Self.castingKey)
        stopKeepAlive()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        pending.reply(["ok": false, "error": "connect", "message": "Could not connect to the TV"], nil)
    }
}

extension CastBridge: GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        requestCallbacks.removeValue(forKey: request.requestID)?(true, nil)
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        requestCallbacks.removeValue(forKey: request.requestID)?(false, error.localizedDescription)
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        requestCallbacks.removeValue(forKey: request.requestID)?(false, "Cancelled")
    }
}
