import Foundation

/// The Pi's numbers, as /api/widget/stats sends them (the Dashboard's, compact).
struct ServerStats: Codable, Equatable {
    struct Usage: Codable, Equatable {
        var used: Double
        var total: Double
        var share: Double { total > 0 ? min(1, max(0, used / total)) : 0 }
    }

    struct Disk: Codable, Equatable {
        var name: String
        var used: Double
        var total: Double
        var share: Double { total > 0 ? min(1, max(0, used / total)) : 0 }
    }

    struct Network: Codable, Equatable {
        var down: Double?
        var up: Double?
    }

    struct Containers: Codable, Equatable {
        var running: Int
        var total: Int
    }

    /// A reading a minute over the last hour, for the chart.
    struct Point: Codable, Equatable {
        var t: Double
        var cpu: Double?
        var temp: Double?
    }

    /// Something running on the Pi: a Docker container or a screen session.
    struct Service: Codable, Equatable {
        var name: String
        var up: Bool
    }

    var at: Date
    var name: String?
    var cpuPercent: Double?
    var load: Double?
    var cores: Int?
    var temperature: Double?
    var memory: Usage
    var disks: [Disk]
    var network: Network
    var uptime: Double
    var containers: Containers
    var sessions: Int
    var history: [Point]?
    var services: [Service]?

    enum FetchError: Error {
        /// The site doesn't know the token (it was made again).
        case rejected
        /// An answer, but not from the Pi: Cloudflare or nginx with the Pi down.
        case server(Int)
    }

    /// Fetches the latest from the site with the widget's token.
    static func fetch(token: String) async throws -> ServerStats {
        try await get(SharedStore.statsURL, token: token, timeout: 12)
    }

    /// One of the widgets' feeds on the site (/api/widget/...).
    static func get<T: Decodable>(_ url: URL, token: String, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw FetchError.rejected }
        guard status == 200 else { throw FetchError.server(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Whether this phone can reach the internet at all (Apple's own page
    /// for checking that), to tell the Pi being down from the phone being
    /// offline.
    static func internetReachable() async -> Bool {
        let request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        guard let result = try? await URLSession.shared.data(for: request) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// Something like the Dashboard would show, for when the widget hasn't
    /// heard anything yet (the widget gallery's preview).
    static let sample = ServerStats(
        at: Date(), name: "raspberrypi", cpuPercent: 12, load: 0.6, cores: 4, temperature: 51,
        memory: Usage(used: 2.9e9, total: 8.4e9),
        disks: [Disk(name: "SD card", used: 21e9, total: 62e9), Disk(name: "Vault", used: 2.3e12, total: 4e12)],
        network: Network(down: 1.2e6, up: 3.4e5), uptime: 3 * 86400 + 4 * 3600,
        containers: Containers(running: 3, total: 3), sessions: 2,
        history: (0..<60).map { i in
            let x = Double(i)
            return Point(t: Date().timeIntervalSince1970 - Double(60 - i) * 60,
                         cpu: 10 + 8 * sin(x / 6) + (i > 44 && i < 50 ? 35 : 0),
                         temp: 48 + 3 * sin(x / 9) + (i > 44 && i < 52 ? 6 : 0))
        },
        services: [Service(name: "website", up: true), Service(name: "radagon", up: true),
                   Service(name: "minecraft", up: true), Service(name: "flowsmp", up: false)]
    )
}

enum StatsFormat {
    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func speed(_ value: Double?) -> String {
        guard let value else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
