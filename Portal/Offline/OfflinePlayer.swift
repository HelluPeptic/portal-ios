import UIKit
import AVKit

/// Plays a download full screen in the iPhone's own player, from where it
/// was left. The subtitles are separate WebVTT files, which that player
/// can't take, so they're drawn over the picture here, under its controls.
/// Where it got to is saved as it plays, for the site (OfflineStore's
/// pendingProgress).
final class OfflinePlayback: NSObject {
    /// The one playing, kept until it's closed.
    private static var current: OfflinePlayback?
    /// Called once a player closes (WebViewController hands the site where
    /// it was left).
    static var onClose: (() -> Void)?

    static func play(_ item: String, from presenter: UIViewController) {
        guard let entry = OfflineStore.shared.items.first(where: { $0.item == item && $0.state == .done }) else { return }
        current?.finish()
        let playback = OfflinePlayback(entry)
        current = playback
        playback.controller.modalPresentationStyle = .fullScreen
        presenter.present(playback.controller, animated: true)
    }

    private let item: String
    private let resumeAt: Double
    private let controller = AVPlayerViewController()
    private let player: AVPlayer
    private let subtitleLabel = UILabel()
    private var subtitleBottom: NSLayoutConstraint?
    private var cues: [SubtitleCue] = []
    private var cueIndex = 0
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var lastSaved = -100.0
    private var started = false
    private var inPictureInPicture = false
    private var finished = false

    private init(_ entry: OfflineItem) {
        item = entry.item
        resumeAt = entry.position > 10 && entry.position < entry.watchedFrom ? entry.position : 0
        let playerItem = AVPlayerItem(url: OfflineStore.shared.videoFile(entry))
        player = AVPlayer(playerItem: playerItem)
        super.init()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.loadViewIfNeeded()
        setUpSubtitles(entry)

        // Starts once it's ready, from where it was left.
        observations.append(playerItem.observe(\.status, options: [.initial, .new]) { [weak self] playerItem, _ in
            guard playerItem.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.begin() }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            self?.tick(time.seconds)
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(playedToEnd), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        center.addObserver(self, selector: #selector(save), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func begin() {
        guard !started else { return }
        started = true
        if resumeAt > 0 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player.play()
            }
        } else {
            player.play()
        }
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        if !cues.isEmpty { showCue(at: time) }
        if started && abs(time - lastSaved) >= 10 { save() }
        // Closed some way the player didn't say.
        if started && !inPictureInPicture && controller.viewIfLoaded?.window == nil && controller.presentingViewController == nil {
            finish()
        }
    }

    @objc private func save() {
        guard started, let current = player.currentItem else { return }
        let time = current.currentTime().seconds
        guard time.isFinite else { return }
        lastSaved = time
        OfflineStore.shared.setPosition(item, time, duration: current.duration.seconds)
    }

    @objc private func playedToEnd() {
        guard let current = player.currentItem else { return }
        let duration = current.duration.seconds
        guard duration.isFinite else { return }
        lastSaved = duration
        OfflineStore.shared.setPosition(item, duration, duration: duration)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        save()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
        if Self.current === self { Self.current = nil }
        Self.onClose?()
    }

    // MARK: - Subtitles

    private func setUpSubtitles(_ entry: OfflineItem) {
        guard let index = entry.subtitle, index < entry.subtitles.count,
              let data = try? Data(contentsOf: OfflineStore.shared.subtitleFile(entry, index)),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let overlay = controller.contentOverlayView else { return }
        cues = SubtitleCue.parse(webVTT: text)
        guard !cues.isEmpty else { return }
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        // An outline of sorts, like the site's subtitles on a TV.
        subtitleLabel.layer.shadowColor = UIColor.black.cgColor
        subtitleLabel.layer.shadowOpacity = 1
        subtitleLabel.layer.shadowRadius = 2.5
        subtitleLabel.layer.shadowOffset = .zero
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(subtitleLabel)
        let bottom = subtitleLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -24)
        subtitleBottom = bottom
        NSLayoutConstraint.activate([
            subtitleLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottom
        ])
        observations.append(controller.observe(\.videoBounds, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.placeSubtitles() }
        })
    }

    /// Near the bottom of the picture itself, not of the screen (in portrait
    /// the picture sits in the middle), and sized to it.
    private func placeSubtitles() {
        guard let overlay = controller.contentOverlayView, let view = controller.viewIfLoaded else { return }
        let video = overlay.convert(controller.videoBounds, from: view)
        guard video.height > 0 else { return }
        subtitleBottom?.constant = -(max(0, overlay.bounds.maxY - video.maxY) + video.height * 0.06)
        subtitleLabel.font = .systemFont(ofSize: max(15, min(30, video.height * 0.055)), weight: .semibold)
    }

    private func showCue(at time: Double) {
        // From the last one shown, since time mostly goes forward.
        if cueIndex >= cues.count || cues[cueIndex].start > time { cueIndex = 0 }
        while cueIndex + 1 < cues.count && cues[cueIndex + 1].start <= time { cueIndex += 1 }
        let cue = cues[cueIndex]
        let text = cue.start <= time && time < cue.end ? cue.text : ""
        if subtitleLabel.text != text { subtitleLabel.text = text }
    }
}

extension OfflinePlayback: AVPlayerViewControllerDelegate {
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled, !self.inPictureInPicture else { return }
            self.finish()
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        if playerViewController.viewIfLoaded?.window == nil { finish() }
    }

    // Back from picture in picture to full screen.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard playerViewController.presentingViewController == nil,
              var top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
            return completionHandler(true)
        }
        while let presented = top.presentedViewController { top = presented }
        top.present(playerViewController, animated: true) { completionHandler(true) }
    }
}

/// One line (or two) of subtitles, from a WebVTT file.
struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String

    static func parse(webVTT text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timing].components(separatedBy: "-->")
            let endPart = times.count == 2 ? times[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) : nil
            guard let start = seconds(times[0]), let endPart, let end = seconds(endPart) else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03.456", "02:03.456" or "02:03,456" in seconds.
    private static func seconds(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
