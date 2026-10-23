import UIKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// "Peptic's Workshop" in the share menu: what's shared is uploaded to The
/// Cache, into its "From iPhone" folder, with the app's own login (the app
/// keeps a copy of it in the app group, SharedStore.sessionCookie). Photos,
/// videos and files go as they are; a link becomes a .url file (opens with
/// a double-click on Windows) and text a .txt file. A video can go on into
/// the Vault from there: the Vault's upload form has "Pick from The Cache".
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(inputs) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var size: Int64
        var file: URL
        var thumbnail: UIImage?
        var progress: Double = 0
        var done = false
        var error: String?
    }

    enum Phase { case loading, ready, sending, done }

    @Published var items: [Item] = []
    @Published var phase = Phase.loading
    @Published var problem: String?

    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    static let folder = "From iPhone"
    private static let site = URL(string: "https://home.hellupeptic.org")!
    private static let chunkSize = 16 * 1024 * 1024

    func load(_ inputs: [NSExtensionItem]) async {
        for input in inputs {
            for provider in input.attachments ?? [] {
                if let item = await ShareReader.item(from: provider) { items.append(item) }
            }
        }
        phase = .ready
        if SharedStore.sessionCookie == nil {
            problem = "Open Peptic's Workshop and log in first, then share again."
        } else if items.isEmpty {
            problem = "There's nothing here that can be saved."
        }
        for index in items.indices {
            let file = items[index].file
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 88, height: 88), scale: 3, representationTypes: .thumbnail)
            if let thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                if index < items.count, items[index].file == file { items[index].thumbnail = thumb.uiImage }
            }
        }
    }

    // MARK: Sending

    func send() {
        guard let cookie = SharedStore.sessionCookie, !items.isEmpty else { return }
        phase = .sending
        Task {
            for index in items.indices where !items[index].done {
                items[index].error = nil
                do {
                    try await upload(index, cookie: cookie)
                    items[index].done = true
                    items[index].progress = 1
                } catch {
                    items[index].error = error.localizedDescription
                }
            }
            phase = items.allSatisfy(\.done) ? .done : .ready
            if phase == .done {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                finish()
            }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private func request(_ path: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.site)!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("site_session=\(cookie)", forHTTPHeaderField: "Cookie")
        return request
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 302 { throw Failure(errorDescription: "Log in again in the app, then try again.") }
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(errorDescription: message ?? "The site said no (\(status)).")
        }
    }

    /// The Cache's own chunked upload (as the site does it): pieces of
    /// 16 MB, then the server puts them together.
    private func upload(_ index: Int, cookie: String) async throws {
        let item = items[index]
        let uploadId = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let handle = try FileHandle(forReadingFrom: item.file)
        defer { try? handle.close() }
        let chunks = max(1, Int((item.size + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)))
        for chunk in 0..<chunks {
            let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
            var request = request("/api/cache/upload/chunk?uploadId=\(uploadId)&index=\(chunk)", cookie: cookie)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (body, response) = try await URLSession.shared.upload(for: request, from: data)
            try check(response, body)
            items[index].progress = Double(chunk + 1) / Double(chunks) * 0.95
        }
        var finalize = request("/api/cache/upload/finalize", cookie: cookie)
        finalize.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finalize.httpBody = try JSONSerialization.data(withJSONObject: [
            "uploadId": uploadId, "totalChunks": chunks, "filename": "\(Self.folder)/\(item.name)", "path": "/"
        ])
        let (body, response) = try await URLSession.shared.data(for: finalize)
        try check(response, body)
        guard let jobId = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["jobId"] as? String else { return }
        // Wait for it to be put together, so "Saved" means saved.
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 500_000_000)
            var status = URLRequest(url: URL(string: "/api/cache/upload-status/\(jobId)", relativeTo: Self.site)!)
            status.httpShouldHandleCookies = false
            status.setValue("site_session=\(cookie)", forHTTPHeaderField: "Cookie")
            guard let (data, _) = try? await URLSession.shared.data(for: status),
                  let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if job["status"] as? String == "done" { return }
            if job["status"] as? String == "error" { throw Failure(errorDescription: job["error"] as? String ?? "It couldn't be saved.") }
        }
    }
}

/// Reads what was shared into files to send (off the main thread, in the
/// item providers' own callbacks).
enum ShareReader {
    static func item(from provider: NSItemProvider) async -> ShareModel.Item? {
        // Photos and videos as the files they are, then links and text,
        // then any other file.
        for type in [UTType.movie, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let item = await fileItem(provider, type) { return item }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadObject(URL.self, from: provider), url.scheme?.hasPrefix("http") == true {
            let name = (url.host ?? "Link").replacingOccurrences(of: "www.", with: "")
            return textItem("[InternetShortcut]\r\nURL=\(url.absoluteString)\r\n", name: "\(name) \(stamp()).url")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let text = await loadObject(String.self, from: provider) {
            return textItem(text, name: "Note \(stamp()).txt")
        }
        for type in [UTType.data, .item] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let item = await fileItem(provider, type) { return item }
        }
        return nil
    }

    private static func loadObject<T: _ObjectiveCBridgeable>(_ type: T.Type, from provider: NSItemProvider) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// A copy of the file in this extension's own temporary folder (the one
    /// handed over is only there while its callback runs).
    private static func fileItem(_ provider: NSItemProvider, _ type: UTType) async -> ShareModel.Item? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var name = url.lastPathComponent
                if let suggested = provider.suggestedName, !suggested.isEmpty {
                    name = suggested.contains(".") || url.pathExtension.isEmpty ? suggested : "\(suggested).\(url.pathExtension)"
                }
                name = clean(name)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let target = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
                    continuation.resume(returning: ShareModel.Item(name: name, size: size, file: target))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func textItem(_ text: String, name: String) -> ShareModel.Item? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(clean(name))
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? Data(text.utf8).write(to: target)) != nil else { return nil }
        return ShareModel.Item(name: target.lastPathComponent, size: Int64(text.utf8.count), file: target)
    }

    private static func clean(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Shared \(stamp())" : cleaned
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH.mm"
        return format.string(from: Date())
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    private static let accent = Color(red: 1, green: 0x6b / 255, blue: 0x6b / 255)

    var body: some View {
        NavigationStack {
            List {
                if model.phase == .loading {
                    HStack { ProgressView(); Text("Getting it ready").foregroundStyle(.secondary) }
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(model.items) { item in row(item) }
                } footer: {
                    if !model.items.isEmpty {
                        Text(model.phase == .sending
                             ? "Keep this open until it's done."
                             : "Saved in The Cache, in the \(ShareModel.folder) folder. A video can go into the Vault from there.")
                    }
                }
            }
            .navigationTitle(model.phase == .done ? "Saved" : "Save to The Cache")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }.disabled(model.phase == .done)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .sending {
                        ProgressView()
                    } else if model.phase == .done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(model.items.contains { $0.error != nil } ? "Try again" : "Save") { model.send() }
                            .bold()
                            .disabled(model.items.isEmpty || model.problem != nil || model.phase != .ready)
                    }
                }
            }
        }
        .tint(Self.accent)
        .preferredColorScheme(.dark)
    }

    private func row(_ item: ShareModel.Item) -> some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: item.name.hasSuffix(".url") ? "link" : "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let error = item.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if item.done {
                    Text("Saved").font(.footnote).foregroundStyle(.green)
                } else if model.phase == .sending && item.progress > 0 {
                    ProgressView(value: item.progress)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
