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

    /// Fetches the latest from the site with the widget's token.
    static func fetch(token: String) async throws -> ServerStats {
        var request = URLRequest(url: SharedStore.statsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
        }
        return try decoder.decode(ServerStats.self, from: data)
    }

    /// Something like the Dashboard would show, for when the widget hasn't
    /// heard anything yet (the widget gallery's preview).
    static let sample = ServerStats(
        at: Date(), name: "raspberrypi", cpuPercent: 12, load: 0.6, cores: 4, temperature: 51,
        memory: Usage(used: 2.9e9, total: 8.4e9),
        disks: [Disk(name: "SD card", used: 21e9, total: 62e9), Disk(name: "Vault", used: 2.3e12, total: 4e12)],
        network: Network(down: 1.2e6, up: 3.4e5), uptime: 3 * 86400 + 4 * 3600,
        containers: Containers(running: 3, total: 3), sessions: 2
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
