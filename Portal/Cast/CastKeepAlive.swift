import AVFoundation

/// A silent sound that keeps the app running in the background while a
/// video is on the TV (the app is allowed to play audio in the background),
/// so its connection to the Chromecast stays up. Left alone, iOS freezes the
/// app soon after it leaves the screen, the Chromecast loses its only sender,
/// and one with a paused video throws the video away. The sound mixes with
/// other apps, so music from another app carries on as normal.
final class CastKeepAlive {
    private var player: AVAudioPlayer?
    private var previous: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?

    var isRunning: Bool { player != nil }

    init() {
        // A phone call stops it; it carries on after.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let player = self?.player,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
    }

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        previous = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            if player.play() {
                self.player = player
                return
            }
        } catch {
            // Without it the app gets frozen like before; nothing else to do.
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        restoreSession()
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        restoreSession()
    }

    /// Back to what the app had (videos played in the app keep their sound
    /// with the silent switch on, see AppDelegate).
    private func restoreSession() {
        guard let previous else { return }
        try? AVAudioSession.sharedInstance().setCategory(previous.category, mode: previous.mode, options: previous.options)
        self.previous = nil
    }

    /// One second of silence as a WAV file (8 kHz, 16-bit, mono).
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let samples = Data(count: Int(sampleRate) * 2)
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count))
        data.append(samples)
        return data
    }()
}
