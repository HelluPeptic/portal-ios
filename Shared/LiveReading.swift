import ActivityKit
import Foundation

/// The live panel on the lock screen and in the Dynamic Island (a Live
/// Activity): drawn by LivePanel in the widget, kept up to date every 5
/// seconds by LiveStats in the app.
struct PiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case live
            /// The phone is online but the Pi doesn't answer.
            case serverDown
            /// The phone itself can't reach anything.
            case noInternet
        }

        struct Point: Codable, Hashable {
            var t: Double
            var cpu: Double
        }

        var status: Status
        /// When the Pi sent these numbers.
        var at: Date
        var cpu: Double?
        var temperature: Double?
        var load: Double?
        /// The share of memory in use.
        var memory: Double
        var vaultFree: Double?
        var vaultShare: Double?
        var down: Double?
        var up: Double?
        /// CPU over the last 3 minutes, every 5 seconds.
        var recent: [Point]
    }
}

extension PiActivityAttributes.ContentState {
    init(_ reading: LiveReading) {
        status = .live
        at = reading.at
        cpu = reading.cpuPercent
        temperature = reading.temperature
        load = reading.load
        memory = reading.memory.total > 0 ? min(1, reading.memory.used / reading.memory.total) : 0
        vaultFree = reading.vault.map { $0.total - $0.used }
        vaultShare = reading.vault.map { $0.total > 0 ? min(1, $0.used / $0.total) : 0 }
        down = reading.network.down
        up = reading.network.up
        recent = (reading.recent ?? []).compactMap { point in point.cpu.map { Point(t: point.t, cpu: $0) } }
    }

    /// Something like the Pi would send, for drawing it without one.
    static let sample = PiActivityAttributes.ContentState(
        status: .live, at: Date(), cpu: 14, temperature: 52, load: 0.71, memory: 0.35,
        vaultFree: 1.7e12, vaultShare: 0.57, down: 1.2e6, up: 3.4e5,
        recent: (0..<36).map { i in
            let x = Double(i)
            return Point(t: Date().timeIntervalSince1970 - Double(36 - i) * 5,
                         cpu: 9 + 5 * sin(x / 3) + (i > 24 && i < 29 ? 26 : 0))
        }
    )
}

/// The quick numbers from /api/widget/live, which the live panel asks for
/// every 5 seconds (the site leaves out the slow parts of the Dashboard).
struct LiveReading: Decodable {
    struct Usage: Decodable {
        var used: Double
        var total: Double
    }

    struct Network: Decodable {
        var down: Double?
        var up: Double?
    }

    struct Point: Decodable {
        var t: Double
        var cpu: Double?
    }

    static let url = URL(string: "https://home.hellupeptic.org/api/widget/live")!

    var at: Date
    var cpuPercent: Double?
    var load: Double?
    var temperature: Double?
    var memory: Usage
    var vault: Usage?
    var network: Network
    var recent: [Point]?

    static func fetch(token: String) async throws -> LiveReading {
        try await ServerStats.get(url, token: token, timeout: 8)
    }
}
