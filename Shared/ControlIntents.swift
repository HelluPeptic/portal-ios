import AppIntents
import Foundation

// What the Control Center buttons do (PortalWidget/Controls.swift). Both
// the app and the widget extension have these: the live panel's runs in
// the app (only the app can start a Live Activity, so it opens it), the
// server's runs in the widget extension with the widgets' token.

/// Turns the live panel on or off.
@available(iOS 18.0, *)
struct SetLivePanelIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Live panel"
    static let openAppWhenRun = true

    @Parameter(title: "On")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        #if PORTAL_APP
        await LiveStats.shared.set(on: value)
        #endif
        return .result()
    }
}

/// One of the Minecraft servers msc knows (folders in /home/mc).
struct MinecraftServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Minecraft server"
    static let defaultQuery = MinecraftServerQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(dir: String) {
        id = dir
        name = MinecraftServers.niceName(dir)
    }
}

struct MinecraftServerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MinecraftServerEntity] {
        identifiers.map { MinecraftServerEntity(dir: $0) }
    }

    func suggestedEntities() async throws -> [MinecraftServerEntity] {
        try await MinecraftServers.list().map { MinecraftServerEntity(dir: $0.dir) }
    }
}

/// Which server a Control Center button is for, picked when it's added.
@available(iOS 18.0, *)
struct MinecraftServerConfig: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Minecraft server"

    @Parameter(title: "Server")
    var server: MinecraftServerEntity?
}

/// Starts or stops the button's server.
@available(iOS 18.0, *)
struct SetMinecraftServerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start or stop a Minecraft server"

    @Parameter(title: "Server")
    var server: MinecraftServerEntity?

    @Parameter(title: "Running")
    var value: Bool

    init() {}

    init(server: MinecraftServerEntity?) {
        self.server = server
    }

    func perform() async throws -> some IntentResult {
        if let server { try await MinecraftServers.set(server.id, running: value) }
        return .result()
    }
}

/// msc's servers through the site (/api/widget/msc), with the widgets' token.
enum MinecraftServers {
    struct Server: Decodable {
        var dir: String
        var type: String?
        var version: String?
        var state: String
    }

    private struct List: Decodable { var servers: [Server] }

    static let url = URL(string: "https://home.hellupeptic.org/api/widget/msc")!

    static func list() async throws -> [Server] {
        guard let token = SharedStore.token else { return [] }
        let list: List = try await ServerStats.get(url, token: token, timeout: 10)
        return list.servers
    }

    static func set(_ dir: String, running: Bool) async throws {
        guard let token = SharedStore.token else { return }
        var request = URLRequest(url: url.appendingPathComponent(dir).appendingPathComponent(running ? "start" : "stop"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    /// "Zavtic_fabric_26.2" as "Zavtic", like the site shows it.
    static func niceName(_ dir: String) -> String {
        let parts = dir.split(separator: "_")
        let types: Set<String> = ["vanilla", "paper", "fabric", "forge", "folia", "neoforge", "velocity"]
        if parts.count >= 3, types.contains(String(parts[parts.count - 2]).lowercased()) {
            return parts.dropLast(2).joined(separator: " ")
        }
        return dir.replacingOccurrences(of: "_", with: " ")
    }
}
