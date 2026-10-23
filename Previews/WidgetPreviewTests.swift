import XCTest
import SwiftUI
import WidgetKit

/// Draws the widgets as pictures, at an iPhone's widget sizes, to look at
/// them without a phone. Run by the "Widget previews" workflow on GitHub's
/// iPhone simulator; each picture is printed to the log as base64
/// ("WIDGET-PNG name data") for previews.yml to save.
final class WidgetPreviewTests: XCTestCase {
    private let background = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0f / 255)

    @MainActor
    func testRenderWidgets() throws {
        var stats = ServerStats.sample
        stats.at = Date().addingTimeInterval(-40)
        let live = StatsEntry(date: Date(), stats: stats, state: .live)
        var hot = stats
        hot.temperature = 78
        hot.cpuPercent = 91
        hot.disks[1].used = hot.disks[1].total * 0.96
        let busy = StatsEntry(date: Date(), stats: hot, state: .live)
        var earlier = stats
        earlier.at = Date().addingTimeInterval(-14 * 60)
        let serverDown = StatsEntry(date: Date(), stats: earlier, state: .serverDown)
        let noInternet = StatsEntry(date: Date(), stats: earlier, state: .noInternet)
        let unconnected = StatsEntry(date: Date(), stats: nil, state: .notConnected)

        // Home screen, iPhone sizes in points.
        let small = CGSize(width: 170, height: 170)
        let medium = CGSize(width: 364, height: 170)
        let large = CGSize(width: 364, height: 382)
        save("home-small", homeScreen(ServerWidgetView(entry: live, familyOverride: .systemSmall), size: small))
        save("home-medium", homeScreen(ServerWidgetView(entry: live, familyOverride: .systemMedium), size: medium))
        save("home-large", homeScreen(ServerWidgetView(entry: live, familyOverride: .systemLarge), size: large))
        save("home-medium-busy", homeScreen(ServerWidgetView(entry: busy, familyOverride: .systemMedium), size: medium))
        save("home-small-offline", homeScreen(ServerWidgetView(entry: serverDown, familyOverride: .systemSmall), size: small))
        save("home-small-nointernet", homeScreen(ServerWidgetView(entry: noInternet, familyOverride: .systemSmall), size: small))
        save("home-medium-offline", homeScreen(ServerWidgetView(entry: serverDown, familyOverride: .systemMedium), size: medium))
        save("home-large-offline", homeScreen(ServerWidgetView(entry: serverDown, familyOverride: .systemLarge), size: large))
        save("home-small-unconnected", homeScreen(ServerWidgetView(entry: unconnected, familyOverride: .systemSmall), size: small))

        // Lock screen: white on the wallpaper, like iOS draws them.
        for metric in [GaugeMetric.cpu, .temperature, .memory, .vault] {
            save("lock-gauge-\(metric)", lockScreen(GaugeWidgetView(entry: live, metric: metric), size: CGSize(width: 76, height: 76)))
        }
        save("lock-rectangular", lockScreen(ServerWidgetView(entry: live, familyOverride: .accessoryRectangular), size: CGSize(width: 172, height: 76)))
        save("lock-rectangular-offline", lockScreen(ServerWidgetView(entry: serverDown, familyOverride: .accessoryRectangular), size: CGSize(width: 172, height: 76)))
        save("lock-gauge-offline", lockScreen(GaugeWidgetView(entry: serverDown, metric: .cpu), size: CGSize(width: 76, height: 76)))
        save("lock-inline-offline", lockScreen(ServerWidgetView(entry: serverDown, familyOverride: .accessoryInline), size: CGSize(width: 260, height: 26)))
        save("lock-inline", lockScreen(ServerWidgetView(entry: live, familyOverride: .accessoryInline), size: CGSize(width: 260, height: 26)))

        // The live panel on the lock screen, and in the Dynamic Island.
        let panel = PiActivityAttributes.ContentState.sample
        var panelDown = panel
        panelDown.status = .serverDown
        panelDown.at = Date().addingTimeInterval(-90)
        var panelHot = panel
        panelHot.cpu = 88
        panelHot.temperature = 71
        panelHot.recent = panel.recent.enumerated().map { i, point in
            .init(t: point.t, cpu: i > 26 ? 70 + Double(i - 26) * 2 : point.cpu)
        }
        save("live-lock", livePanel(LivePanelView(state: panel)))
        save("live-lock-busy", livePanel(LivePanelView(state: panelHot)))
        save("live-lock-offline", livePanel(LivePanelView(state: panelDown)))
        save("live-lock-stale", livePanel(LivePanelView(state: panel, stale: true)))
        save("live-island-expanded", islandExpanded(LiveIsland(state: panel)))
        save("live-island-expanded-offline", islandExpanded(LiveIsland(state: panelDown)))
        save("live-island-compact", islandCompact(LiveIsland(state: panel)))
        save("live-island-compact-offline", islandCompact(LiveIsland(state: panelDown)))
        save("live-island-minimal", islandMinimal(LiveIsland(state: panel)))
    }

    /// The lock screen's width for a Live Activity, at the height it takes.
    private func livePanel<V: View>(_ view: V) -> some View {
        view
            .frame(width: 364)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    /// Roughly how iOS lays out the expanded Dynamic Island's regions.
    private func islandExpanded(_ island: LiveIsland) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                island.cpuBlock
                Spacer()
                island.temperatureBlock
            }
            island.bottom
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 371)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func islandCompact(_ island: LiveIsland) -> some View {
        HStack(spacing: 0) {
            island.compactLeading.padding(.leading, 14)
            Spacer(minLength: 0)
            island.compactTrailing.padding(.trailing, 14)
        }
        .frame(width: 250, height: 37)
        .background(Color.black)
        .clipShape(Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func islandMinimal(_ island: LiveIsland) -> some View {
        island.minimal
            .frame(width: 37, height: 37)
            .background(Color.black)
            .clipShape(Circle())
            .environment(\.colorScheme, .dark)
    }

    private func homeScreen<V: View>(_ view: V, size: CGSize) -> some View {
        view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private func lockScreen<V: View>(_ view: V, size: CGSize) -> some View {
        view
            .foregroundStyle(.white)
            .tint(.white)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
    }

    @MainActor
    private func save<V: View>(_ name: String, _ view: V) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.uiImage, let png = image.pngData() else {
            XCTFail("Could not draw \(name)")
            return
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("WIDGET-PNG \(name) \(png.base64EncodedString())")
    }
}
