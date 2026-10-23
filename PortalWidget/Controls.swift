import WidgetKit
import SwiftUI
import AppIntents

// Control Center buttons (iOS 18): the live panel on or off, and a
// Minecraft server started or stopped. What they do is in
// Shared/ControlIntents.swift.

@available(iOS 18.0, *)
struct LivePanelControl: ControlWidget {
    static let kind = "LivePanel"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Value()) { isOn in
            ControlWidgetToggle("Live panel", isOn: isOn, action: SetLivePanelIntent()) { on in
                Label(on ? "On" : "Off", systemImage: "gauge.with.dots.needle.67percent")
            }
        }
        .displayName("Live panel")
        .description("The Pi's numbers on the lock screen, every 5 seconds.")
    }

    struct Value: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { SharedStore.liveRunning }
    }
}

@available(iOS 18.0, *)
struct MinecraftServerControl: ControlWidget {
    static let kind = "MinecraftServer"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Value()) { state in
            ControlWidgetToggle(isOn: state.running, action: SetMinecraftServerIntent(server: state.server)) {
                Label(state.name, systemImage: "cube")
            } valueLabel: { on in
                Text(on ? "Running" : "Stopped")
            }
        }
        .displayName("Minecraft server")
        .description("Start or stop one of your servers.")
        .promptsForUserConfiguration()
    }

    struct State {
        var server: MinecraftServerEntity?
        var name: String
        var running: Bool
    }

    struct Value: AppIntentControlValueProvider {
        func previewValue(configuration: MinecraftServerConfig) -> State {
            State(server: configuration.server, name: configuration.server?.name ?? "Server", running: false)
        }

        func currentValue(configuration: MinecraftServerConfig) async throws -> State {
            guard let server = configuration.server else { return previewValue(configuration: configuration) }
            let found = try? await MinecraftServers.list().first { $0.dir == server.id }
            // Starting counts as on, so the button doesn't flip back meanwhile.
            let running = ["running", "starting", "restarting"].contains(found?.state ?? "")
            return State(server: server, name: server.name, running: running)
        }
    }
}
