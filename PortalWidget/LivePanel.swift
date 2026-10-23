import WidgetKit
import SwiftUI
import ActivityKit
import Charts

/// The live panel (LiveStats in the app updates it every 5 seconds): on the
/// lock screen, and in the Dynamic Island on iPhones that have one. Tapping
/// it opens the app.
struct PiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiActivityAttributes.self) { context in
            LivePanelView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.text)
        } dynamicIsland: { context in
            let island = LiveIsland(state: context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { island.cpuBlock }
                DynamicIslandExpandedRegion(.trailing) { island.temperatureBlock }
                DynamicIslandExpandedRegion(.bottom) { island.bottom }
            } compactLeading: {
                island.compactLeading
            } compactTrailing: {
                island.compactTrailing
            } minimal: {
                island.minimal
            }
            .keylineTint(island.keyline)
        }
    }
}

/// The panel on the lock screen: CPU with its last 3 minutes, the
/// temperature, RAM and the Vault, and the network.
struct LivePanelView: View {
    let state: PiActivityAttributes.ContentState
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Group {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: -2) {
                        Text("CPU").font(.caption2).foregroundStyle(Palette.dim)
                        Text(state.cpuText)
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Palette.text)
                            .rolling(state.cpu)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 88, alignment: .leading)
                    LiveLine(points: state.recent, color: state.cpuColor)
                        .frame(height: 46)
                }
                HStack(spacing: 16) {
                    LiveMeter(label: "RAM", value: StatsFormat.percent(state.memory), share: state.memory, color: state.memoryColor)
                    if let free = state.vaultFree, let share = state.vaultShare {
                        LiveMeter(label: "Vault", value: StatsFormat.bytes(free) + " free", share: share, color: state.vaultColor)
                    }
                }
                HStack(spacing: 10) {
                    Label(StatsFormat.speed(state.down), systemImage: "arrow.down")
                        .rolling(state.down)
                    Label(StatsFormat.speed(state.up), systemImage: "arrow.up")
                        .rolling(state.up)
                    Spacer(minLength: 0)
                    Text(state.load.map { String(format: "Load %.2f", $0) } ?? "")
                        .rolling(state.load)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.dim)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
            .opacity(state.isDown || stale ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The name and temperature, or a banner saying why the numbers are old
    /// (the lock screen gives a Live Activity 160 points at most).
    @ViewBuilder private var header: some View {
        if state.isDown {
            banner(state.downTitle, icon: state.downIcon, color: state.downColor,
                   detail: Text(state.status == .serverDown ? "Last seen " : "Last update ") + Text(state.at, style: .time))
        } else if stale {
            banner("Not updating", icon: "pause.circle.fill", color: Palette.warn.opacity(0.85),
                   detail: Text("Open the app to carry on"))
        } else {
            HStack(spacing: 6) {
                Circle().fill(Palette.good).frame(width: 7, height: 7)
                Text("Raspberry Pi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Image(systemName: "thermometer.medium").font(.caption2).foregroundStyle(state.temperatureColor)
                Text(state.temperatureText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.temperatureColor)
                    .rolling(state.temperature)
            }
        }
    }

    private func banner(_ title: String, icon: String, color: Color, detail: Text) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
            Spacer(minLength: 4)
            detail
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color))
    }
}

/// The Dynamic Island: CPU and the temperature either side of the camera,
/// and all of it when held.
struct LiveIsland {
    let state: PiActivityAttributes.ContentState
    var stale = false

    private var dimmed: Bool { state.isDown || stale }

    var keyline: Color { state.isDown ? state.downColor : state.cpuColor }

    var cpuBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("CPU", systemImage: "cpu")
                .font(.caption2)
                .foregroundStyle(Palette.dim)
            Text(state.cpuText)
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.text)
                .rolling(state.cpu)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .opacity(dimmed ? 0.4 : 1)
    }

    var temperatureBlock: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Label("Temp", systemImage: "thermometer.medium")
                .font(.caption2)
                .foregroundStyle(Palette.dim)
            Text(state.temperatureText)
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(state.temperatureColor)
                .rolling(state.temperature)
                .lineLimit(1)
        }
        .padding(.trailing, 6)
        .opacity(dimmed ? 0.4 : 1)
    }

    var bottom: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isDown {
                Label(state.downTitle, systemImage: state.downIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.downColor)
            } else if stale {
                Label("Not updating. Open the app to carry on.", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(1)
            }
            Group {
                LiveLine(points: state.recent, color: state.cpuColor)
                    .frame(height: 34)
                HStack(spacing: 10) {
                    Text("RAM \(StatsFormat.percent(state.memory))")
                        .rolling(state.memory)
                    if let free = state.vaultFree {
                        Text("Vault \(StatsFormat.bytes(free)) free")
                    }
                    Spacer(minLength: 0)
                    Label(StatsFormat.speed(state.down), systemImage: "arrow.down")
                        .rolling(state.down)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.dim)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
            .opacity(dimmed ? 0.4 : 1)
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder var compactLeading: some View {
        if state.isDown {
            Image(systemName: state.downIcon)
                .foregroundStyle(state.downColor)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.cpuColor)
                Text(state.cpuText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .rolling(state.cpu)
            }
            .opacity(stale ? 0.5 : 1)
        }
    }

    @ViewBuilder var compactTrailing: some View {
        if state.isDown {
            Text("Off")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(state.downColor)
        } else {
            Text(state.temperature.map { "\(Int($0.rounded()))°" } ?? "-")
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(state.temperatureColor)
                .rolling(state.temperature)
                .opacity(stale ? 0.5 : 1)
        }
    }

    @ViewBuilder var minimal: some View {
        if state.isDown {
            Image(systemName: state.downIcon)
                .foregroundStyle(state.downColor)
        } else {
            Text(state.cpu.map { "\(Int($0.rounded()))" } ?? "-")
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(state.cpuColor)
                .rolling(state.cpu)
        }
    }
}

/// CPU over the last 3 minutes. Each point keeps its identity by its time,
/// so every update slides the line left with the newest reading coming in
/// at the right.
struct LiveLine: View {
    let points: [PiActivityAttributes.ContentState.Point]
    let color: Color

    var body: some View {
        let top = max(25, (points.map(\.cpu).max() ?? 0) + 5)
        let end = points.last?.t ?? 0
        Chart {
            ForEach(points, id: \.t) { point in
                AreaMark(x: .value("Time", point.t), yStart: .value("Base", 0.0), yEnd: .value("CPU", point.cpu))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.t), y: .value("CPU", point.cpu))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: (end - 175)...end)
        .chartYScale(domain: 0...top)
        .animation(.widgetUpdate, value: end)
    }
}

/// A bar with its label and value on one line above it.
private struct LiveMeter: View {
    let label: String
    let value: String
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 2)
                Text(value)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.dim)
                    .rolling(share)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color).frame(width: max(5, geo.size.width * min(1, max(0, share))))
                }
                .animation(.widgetUpdate, value: share)
            }
            .frame(height: 5)
        }
    }
}

private extension PiActivityAttributes.ContentState {
    var isDown: Bool { status != .live }
    var cpuText: String { cpu.map { "\(Int($0.rounded()))%" } ?? "-" }
    var temperatureText: String { temperature.map { "\(Int($0.rounded()))°C" } ?? "-" }
    var cpuColor: Color { Palette.level(cpu ?? 0, warn: 60, bad: 85) }
    var temperatureColor: Color { Palette.level(temperature ?? 0, warn: 65, bad: 75) }
    var memoryColor: Color { Palette.level(memory, warn: 0.8, bad: 0.92) }
    var vaultColor: Color { Palette.level(vaultShare ?? 0, warn: 0.85, bad: 0.95) }
    var downTitle: String { status == .serverDown ? "Server offline" : "No connection" }
    var downIcon: String { status == .serverDown ? "exclamationmark.triangle.fill" : "wifi.slash" }
    var downColor: Color { status == .serverDown ? Palette.bad : Palette.warn.opacity(0.85) }
}
