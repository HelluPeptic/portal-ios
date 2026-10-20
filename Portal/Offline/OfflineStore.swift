import UIKit

/// A movie or episode saved on the phone to watch without a connection. The
/// site hands over everything about it (/api/vault/download-link), with a
/// token in its links, since a background download has no login.
struct OfflineItem: Codable {
    enum State: String, Codable { case downloading, paused, done, failed }

    var id: String              // its folder under Offline/
    var item: String            // the Vault path, which the site knows it by
    var kind: String            // "movie" or "episode"
    var title: String
    var detail: String          // "2002", or "Lupin · Season 3"
    var videoURL: URL
    var posterURL: URL?
    var subtitles: [OfflineSubtitle]
    var size: Int64
    var duration: Double
    var creditsAt: Double?
    var state: State
    var received: Int64
    var message: String?
    var addedAt: Date
    var position: Double        // where it was left, here or on the site
    var unsynced: Bool          // watched here since the site last heard
    var subtitle: Int?          // which subtitles are on; nil is off

    var progress: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }

    /// Where it counts as watched, the same as the site's vaultFinishedAt:
    /// half a minute before the credits, or at 95% of an episode or 90% of a
    /// movie, whichever comes first.
    var watchedFrom: Double {
        let fallback = duration * (kind == "movie" ? 0.9 : 0.95)
        guard let creditsAt, creditsAt > 0 else { return fallback }
        return min(creditsAt - 30, fallback)
    }
}

struct OfflineSubtitle: Codable {
    var label: String
    var lang: String?
    var url: URL
}

extension Notification.Name {
    static let offlineChanged = Notification.Name("offlineChanged")
}

/// Keeps the downloads: one folder each in Application Support/Offline (not
/// backed up to iCloud), and a list of them in index.json. The video comes
/// down in a background URLSession, so it carries on with the app closed;
/// the poster and subtitles are small and come straight away.
final class OfflineStore: NSObject {
    static let shared = OfflineStore()
    static let sessionIdentifier = "org.hellupeptic.portal.offline"

    private(set) var items: [OfflineItem] = []
    /// From iOS, when downloads finished while the app was in the background.
    var backgroundCompletion: (() -> Void)?

    private let root: URL
    private var session: URLSession!
    private var saveTimer: Timer?
    private var lastNotice = Date.distantPast
    private var retries: [String: Int] = [:]

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Offline", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
        load()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        // A download the app lost track of (iOS ended it while the app was
        // closed) waits to be carried on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.findLostDownloads() }
    }

    // MARK: - Files

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func videoFile(_ entry: OfflineItem) -> URL {
        let ext = (entry.item as NSString).pathExtension
        return folder(entry.id).appendingPathComponent("video.\(ext.isEmpty ? "mp4" : ext)")
    }

    func posterFile(_ entry: OfflineItem) -> URL { folder(entry.id).appendingPathComponent("poster.jpg") }

    func subtitleFile(_ entry: OfflineItem, _ index: Int) -> URL {
        folder(entry.id).appendingPathComponent("subtitles-\(index).vtt")
    }

    private func resumeFile(_ id: String) -> URL { folder(id).appendingPathComponent("resume.data") }

    var freeSpace: Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Starting, carrying on, removing

    /// Starts downloading what the site described. Returns why not, if not.
    func start(_ info: [String: Any]) -> String? {
        guard let item = info["item"] as? String, let videoURL = absolute(info["url"]) else { return "Something was missing" }
        if let existing = items.first(where: { $0.item == item }) {
            if existing.state == .done { return nil }
            remove(item)
        }
        let size = (info["size"] as? NSNumber)?.int64Value ?? 0
        if let free = freeSpace, size > 0, free < size + 300 * 1_048_576 {
            return "There isn't room. It needs \(Self.format(size)) and there's \(Self.format(free)) free."
        }
        let kind = info["kind"] as? String ?? "movie"
        var detail = ""
        if kind == "episode" {
            let show = info["showTitle"] as? String ?? ""
            if let season = (info["season"] as? NSNumber)?.intValue {
                detail = show.isEmpty ? "Season \(season)" : "\(show) · Season \(season)"
            } else {
                detail = show
            }
        } else if let year = info["year"] as? String {
            detail = year
        }
        let entry = OfflineItem(
            id: UUID().uuidString,
            item: item,
            kind: kind,
            title: info["title"] as? String ?? "Video",
            detail: detail,
            videoURL: videoURL,
            posterURL: absolute(info["poster"]),
            subtitles: subtitles(from: info),
            size: size,
            duration: (info["duration"] as? NSNumber)?.doubleValue ?? 0,
            creditsAt: (info["creditsAt"] as? NSNumber)?.doubleValue,
            state: .downloading,
            received: 0,
            message: nil,
            addedAt: Date(),
            position: (info["position"] as? NSNumber)?.doubleValue ?? 0,
            unsynced: false,
            subtitle: nil
        )
        try? FileManager.default.createDirectory(at: folder(entry.id), withIntermediateDirectories: true)
        items.append(entry)
        let task = session.downloadTask(with: videoURL)
        task.taskDescription = entry.id
        task.resume()
        fetchExtras(entry)
        changed()
        return nil
    }

    /// Carries on with a download that stopped, from where it got to when
    /// it can. info: a fresh description from the site, if there is one.
    func retry(_ item: String, info: [String: Any]? = nil) {
        guard let i = items.firstIndex(where: { $0.item == item }), items[i].state != .done else { return }
        if let info {
            if let url = absolute(info["url"]) { items[i].videoURL = url }
            if let poster = absolute(info["poster"]) { items[i].posterURL = poster }
            let fresh = subtitles(from: info)
            if !fresh.isEmpty { items[i].subtitles = fresh }
            if let credits = (info["creditsAt"] as? NSNumber)?.doubleValue { items[i].creditsAt = credits }
        }
        let id = items[i].id
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(id)) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeFile(id))
        } else {
            task = session.downloadTask(with: items[i].videoURL)
            items[i].received = 0
        }
        task.taskDescription = id
        task.resume()
        items[i].state = .downloading
        items[i].message = nil
        fetchExtras(items[i])
        changed()
    }

    func remove(_ item: String) {
        guard let i = items.firstIndex(where: { $0.item == item }) else { return }
        let id = items[i].id
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: folder(id))
        items.remove(at: i)
        retries[id] = nil
        changed()
    }

    // MARK: - Watching

    func setPosition(_ item: String, _ position: Double, duration: Double) {
        guard let i = items.firstIndex(where: { $0.item == item }), position.isFinite else { return }
        items[i].position = position
        if duration.isFinite && duration > 0 { items[i].duration = duration }
        items[i].unsynced = true
        saveSoon()
    }

    func setSubtitle(_ item: String, _ index: Int?) {
        guard let i = items.firstIndex(where: { $0.item == item }) else { return }
        items[i].subtitle = index
        changed()
    }

    /// Where things were left while watching here, for the site.
    func pendingProgress() -> [[String: Any]] {
        items.filter { $0.unsynced && $0.duration > 0 }.map { ["item": $0.item, "position": $0.position, "duration": $0.duration] }
    }

    /// The site has these now (unless they were watched further since).
    func synced(_ sent: [[String: Any]]) {
        for entry in sent {
            guard let item = entry["item"] as? String,
                  let position = (entry["position"] as? NSNumber)?.doubleValue,
                  let i = items.firstIndex(where: { $0.item == item }),
                  abs(items[i].position - position) < 0.5 else { continue }
            items[i].unsynced = false
        }
        save()
    }

    // MARK: - Keeping the list

    private func load() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let saved = try? JSONDecoder().decode([OfflineItem].self, from: data) else { return }
        // Anything whose files are gone (or never finished arriving) goes.
        items = saved.filter { entry in
            guard FileManager.default.fileExists(atPath: folder(entry.id).path) else { return false }
            return entry.state != .done || FileManager.default.fileExists(atPath: videoFile(entry).path)
        }
    }

    private func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private func saveSoon() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.save() }
    }

    private func changed() {
        save()
        lastNotice = Date()
        NotificationCenter.default.post(name: .offlineChanged, object: nil)
    }

    /// Progress: told twice a second at most, saved every few seconds.
    private func progressed() {
        saveSoon()
        guard Date().timeIntervalSince(lastNotice) > 0.5 else { return }
        lastNotice = Date()
        NotificationCenter.default.post(name: .offlineChanged, object: nil)
    }

    private func findLostDownloads() {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                let running = Set(tasks.compactMap { $0.taskDescription })
                var lost = false
                for i in self.items.indices where self.items[i].state == .downloading && !running.contains(self.items[i].id) {
                    self.items[i].state = .paused
                    lost = true
                }
                if lost { self.changed() }
            }
        }
    }

    // MARK: - Helpers

    private func absolute(_ path: Any?) -> URL? {
        guard let path = path as? String, !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: Portal.siteURL)?.absoluteURL
    }

    private func subtitles(from info: [String: Any]) -> [OfflineSubtitle] {
        ((info["subtitles"] as? [[String: Any]]) ?? []).compactMap { sub in
            guard let url = absolute(sub["url"]) else { return nil }
            return OfflineSubtitle(label: sub["label"] as? String ?? "Subtitles", lang: sub["lang"] as? String, url: url)
        }
    }

    /// The poster and subtitles, which are small.
    private func fetchExtras(_ entry: OfflineItem) {
        var wanted: [(URL, URL)] = []
        if let poster = entry.posterURL { wanted.append((poster, posterFile(entry))) }
        for (index, sub) in entry.subtitles.enumerated() { wanted.append((sub.url, subtitleFile(entry, index))) }
        for (from, to) in wanted where !FileManager.default.fileExists(atPath: to.path) {
            URLSession.shared.dataTask(with: from) { data, response, _ in
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                try? data.write(to: to, options: .atomic)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .offlineChanged, object: nil) }
            }.resume()
        }
    }

    private func index(_ task: URLSessionTask) -> Int? {
        guard let id = task.taskDescription else { return nil }
        return items.firstIndex { $0.id == id }
    }
}

// MARK: - The background session

extension OfflineStore: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let i = index(downloadTask) else { return }
        items[i].received = totalBytesWritten
        if items[i].size <= 0 && totalBytesExpectedToWrite > 0 { items[i].size = totalBytesExpectedToWrite }
        if items[i].state != .downloading {
            items[i].state = .downloading
            items[i].message = nil
        }
        retries[items[i].id] = nil
        progressed()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        guard let i = index(downloadTask) else { return }
        items[i].received = fileOffset
        progressed()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let i = index(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            items[i].state = .failed
            items[i].message = status == 404 ? "It's not in the Vault any more." : "The site wouldn't send it (\(status))."
            changed()
            return
        }
        // Has to be moved before this returns: iOS deletes it after.
        let target = videoFile(items[i])
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            items[i].state = .done
            items[i].received = items[i].size
            items[i].message = nil
            try? FileManager.default.removeItem(at: resumeFile(items[i].id))
        } catch {
            items[i].state = .failed
            items[i].message = "Couldn't save it. \(error.localizedDescription)"
        }
        changed()
        fetchExtras(items[i])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let i = index(task) else { return }
        let nsError = error as NSError
        let id = items[i].id
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile(id), options: .atomic)
        }
        items[i].state = .paused
        items[i].message = nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorNetworkConnectionLost
            ? "Paused, no connection." : nil
        changed()
        // Lost the connection, or iOS stopped it: tried again a few times by
        // itself, a little later each time.
        let attempt = (retries[id] ?? 0) + 1
        retries[id] = attempt
        guard attempt <= 5 else { return }
        let item = items[i].item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt * attempt) * 10) { [weak self] in
            guard let self, let entry = self.items.first(where: { $0.item == item }), entry.state == .paused else { return }
            self.retry(item)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}
