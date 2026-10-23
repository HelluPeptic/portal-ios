import WidgetKit
import SwiftUI
import AppIntents
import Charts

/// The Pi at a glance on the home screen or lock screen: the Dashboard's
/// numbers from /api/widget/stats. iOS decides how often a widget may
/// refresh (every few minutes at best), so it asks every 5 minutes, the app
/// has it refresh whenever you leave it, and on iOS 17 the refresh button
/// does it at once. What's relative to now (how long ago, uptime) counts
/// on by itself in between.
/// The Dashboard: three sizes on the home screen, and a line or two on the
/// lock screen.
struct ServerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ServerStats", provider: StatsProvider()) { entry in
            ServerWidgetView(entry: entry)
        }
        .configurationDisplayName("Server")
        .description("The Pi's numbers from the Dashboard.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

/// One number each, as a round gauge on the lock screen, to line up side
/// by side like a little dashboard.
enum GaugeMetric {
    case cpu, temperature, memory, vault
}

private func gaugeConfiguration(_ metric: GaugeMetric, kind: String, name: String, description: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
        GaugeWidgetView(entry: entry, metric: metric)
    }
    .configurationDisplayName(name)
    .description(description)
    .supportedFamilies([.accessoryCircular])
}

struct CPUGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeConfiguration(.cpu, kind: "ServerCPU", name: "CPU", description: "How busy the Pi is.")
    }
}

struct TemperatureGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeConfiguration(.temperature, kind: "ServerTemperature", name: "Temperature", description: "How hot the Pi is.")
    }
}

struct MemoryGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeConfiguration(.memory, kind: "ServerMemory", name: "RAM", description: "How much of the Pi's memory is in use.")
    }
}

struct VaultGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeConfiguration(.vault, kind: "ServerVault", name: "Vault space", description: "How full the Vault drive is.")
    }
}

struct GaugeWidgetView: View {
    let entry: StatsEntry
    let metric: GaugeMetric

    var body: some View {
        let reading = self.reading
        Gauge(value: reading.share) {
            Text(reading.label)
        } currentValueLabel: {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(reading.value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetBackground()
        .widgetURL(URL(string: "pepticworkshop://dashboard"))
    }

    private var icon: String {
        switch metric {
        case .cpu: return "cpu"
        case .temperature: return "thermometer.medium"
        case .memory: return "memorychip"
        case .vault: return "externaldrive"
        }
    }

    private var reading: (share: Double, value: String, label: String) {
        guard let stats = entry.stats, entry.state != .notConnected else { return (0, "-", "Pi") }
        if entry.state == .offline { return (0, "off", "Pi") }
        switch metric {
        case .cpu:
            return (min(1, (stats.cpuPercent ?? 0) / 100), stats.cpuPercent.map { "\(Int($0.rounded()))" } ?? "-", "CPU")
        case .temperature:
            return (min(1, (stats.temperature ?? 0) / 85), stats.temperature.map { "\(Int($0.rounded()))°" } ?? "-", "°C")
        case .memory:
            return (stats.memory.share, "\(Int((stats.memory.share * 100).rounded()))", "RAM")
        case .vault:
            let disk = stats.disks.first { $0.name == "Vault" } ?? stats.disks.last
            return (disk?.share ?? 0, disk.map { "\(Int(($0.share * 100).rounded()))" } ?? "-", "Vault")
        }
    }
}

// MARK: - Data

struct StatsEntry: TimelineEntry {
    enum State { case live, offline, notConnected }
    let date: Date
    let stats: ServerStats?
    let state: State
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), stats: .sample, state: .live)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        if context.isPreview || SharedStore.token == nil {
            return completion(StatsEntry(date: Date(), stats: SharedStore.lastStats ?? .sample, state: .live))
        }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        Task {
            let entry = await load()
            let minutes: Double = entry.state == .notConnected ? 30 : 5
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(minutes * 60))))
        }
    }

    private func load() async -> StatsEntry {
        guard let token = SharedStore.token else {
            return StatsEntry(date: Date(), stats: nil, state: .notConnected)
        }
        do {
            let stats = try await ServerStats.fetch(token: token)
            SharedStore.lastStats = stats
            return StatsEntry(date: Date(), stats: stats, state: .live)
        } catch {
            return StatsEntry(date: Date(), stats: SharedStore.lastStats, state: .offline)
        }
    }
}

@available(iOS 16.0, *)
struct RefreshStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh"
    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Look

private enum Palette {
    static let background = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0f / 255)
    static let track = Color(red: 0x3a / 255, green: 0x33 / 255, blue: 0x2c / 255)
    static let text = Color(red: 0xf3 / 255, green: 0xef / 255, blue: 0xe9 / 255)
    static let dim = Color(red: 0xa8 / 255, green: 0x9e / 255, blue: 0x93 / 255)
    static let accent = Color(red: 1, green: 0x6b / 255, blue: 0x6b / 255)
    static let good = Color(red: 0x5f / 255, green: 0xd6 / 255, blue: 0x8a / 255)
    static let warn = Color(red: 0xf2 / 255, green: 0xae / 255, blue: 0x40 / 255)
    static let bad = Color(red: 0xe5 / 255, green: 0x48 / 255, blue: 0x4d / 255)

    /// Green, then amber, then red as a number gets close to its limit.
    static func level(_ value: Double, warn warnAt: Double, bad badAt: Double) -> Color {
        value >= badAt ? bad : value >= warnAt ? warn : good
    }
}

private extension View {
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(Palette.background, for: .widget)
        } else {
            background(Palette.background)
        }
    }
}

struct ServerWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: StatsEntry
    /// Set when drawn outside a widget (Previews/WidgetPreviewTests).
    var familyOverride: WidgetFamily?

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    init(entry: StatsEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .widgetURL(URL(string: "pepticworkshop://dashboard"))
    }

    private var stats: ServerStats? { entry.stats }

    // MARK: Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.state == .offline ? "Pi offline" : "Pi · \(temperatureText)")
                .font(.headline)
            Text("CPU \(cpuText) · RAM \(stats.map { StatsFormat.percent($0.memory.share) } ?? "-")")
            if let vault = stats?.disks.last {
                Text("\(vault.name) \(StatsFormat.percent(vault.share)) full")
            }
        }
        .widgetBackground()
    }

    private var inline: some View {
        Text(entry.state == .offline ? "Pi offline" : "Pi \(temperatureText) · CPU \(cpuText)")
            .widgetBackground()
    }

    // MARK: Home screen

    @ViewBuilder private var small: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 8) {
                header(compact: true)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    tile("CPU", cpuText, share: (stats.cpuPercent ?? 0) / 100, color: cpuColor)
                    tile("Temp", temperatureText, share: min(1, (stats.temperature ?? 0) / 85), color: temperatureColor)
                }
                HStack(spacing: 10) {
                    tile("RAM", StatsFormat.percent(stats.memory.share), share: stats.memory.share, color: Palette.level(stats.memory.share, warn: 0.8, bad: 0.92))
                    if let vault = stats.disks.last {
                        tile(vault.name, StatsFormat.percent(vault.share), share: vault.share, color: diskColor(vault))
                    }
                }
            }
            .widgetBackground()
        } else {
            notConnected
        }
    }

    @ViewBuilder private var medium: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 10) {
                header(compact: false)
                HStack(alignment: .center, spacing: 14) {
                    ring(stats)
                    VStack(alignment: .leading, spacing: 7) {
                        bar("RAM", StatsFormat.bytes(stats.memory.used) + " of " + StatsFormat.bytes(stats.memory.total),
                            share: stats.memory.share, color: Palette.level(stats.memory.share, warn: 0.8, bad: 0.92))
                        ForEach(stats.disks, id: \.name) { disk in
                            bar(disk.name, StatsFormat.percent(disk.share) + " full", share: disk.share, color: diskColor(disk))
                        }
                    }
                }
                footer(stats)
            }
            .widgetBackground()
        } else {
            notConnected
        }
    }

    @ViewBuilder private var large: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 8) {
                header(compact: false)
                HStack(spacing: 16) {
                    ring(stats, size: 62)
                    VStack(alignment: .leading, spacing: 6) {
                        figure("Load", stats.load.map { String(format: "%.2f", $0) } ?? "-",
                               note: stats.cores.map { "\($0) cores" })
                        figure("Up", nil, note: nil, since: stats.at.addingTimeInterval(-stats.uptime))
                    }
                    Spacer(minLength: 0)
                }
                bar("RAM", StatsFormat.bytes(stats.memory.used) + " of " + StatsFormat.bytes(stats.memory.total),
                    share: stats.memory.share, color: Palette.level(stats.memory.share, warn: 0.8, bad: 0.92))
                ForEach(stats.disks, id: \.name) { disk in
                    bar(disk.name, StatsFormat.bytes(disk.total - disk.used) + " free of " + StatsFormat.bytes(disk.total),
                        share: disk.share, color: diskColor(disk))
                }
                if let history = stats.history, history.count >= 3 {
                    HStack(spacing: 14) {
                        chart("CPU, last hour", history.compactMap { p in p.cpu.map { (p.t, $0) } },
                              color: Palette.accent, unit: "%", domain: 0...100)
                        chart("Temperature", history.compactMap { p in p.temp.map { (p.t, $0) } },
                              color: Palette.warn, unit: "°C", domain: 30...85)
                    }
                }
                if let services = stats.services, !services.isEmpty {
                    servicesList(services)
                }
                Spacer(minLength: 0)
                footer(stats)
            }
            .widgetBackground()
        } else {
            notConnected
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Palette.dim).frame(width: 7, height: 7)
                Text("Server").font(.caption.weight(.semibold)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 0)
            Text("Open Peptic's Workshop once to show the Pi here.")
                .font(.footnote)
                .foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }

    // MARK: Pieces

    private func header(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.state == .offline ? Palette.bad : Palette.good)
                .frame(width: 7, height: 7)
            Text(entry.state == .offline ? "Offline" : compact ? "Pi" : "Raspberry Pi")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.state == .offline ? Palette.bad : Palette.text)
            Spacer(minLength: 0)
            if !compact, let stats {
                Text(temperatureText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(temperatureColor)
                    .contentTransition(.numericText())
                    .padding(.trailing, 2)
                Text(stats.name ?? "")
                    .font(.caption2)
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
        }
    }

    private func footer(_ stats: ServerStats, showNetwork: Bool = true) -> some View {
        HStack(spacing: 8) {
            if showNetwork {
                Label(StatsFormat.speed(stats.network.down), systemImage: "arrow.down")
                Label(StatsFormat.speed(stats.network.up), systemImage: "arrow.up")
            }
            Spacer(minLength: 0)
            (Text(entry.state == .offline ? "Last seen " : "") + Text(stats.at, style: .relative) + Text(" ago"))
                .multilineTextAlignment(.trailing)
            refreshButton
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Palette.dim)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    @ViewBuilder private var refreshButton: some View {
        if #available(iOS 17.0, *) {
            Button(intent: RefreshStatsIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.track))
            }
            .buttonStyle(.plain)
        }
    }

    private func ring(_ stats: ServerStats, size: CGFloat = 74) -> some View {
        let share = min(1, max(0, (stats.cpuPercent ?? 0) / 100))
        return ZStack {
            Circle().stroke(Palette.track, lineWidth: 8)
            Circle()
                .trim(from: 0, to: share)
                .stroke(cpuColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(cpuText)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .contentTransition(.numericText())
                Text("CPU").font(.caption2).foregroundStyle(Palette.dim)
            }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ label: String, _ value: String, share: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(Palette.dim).lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            meter(share, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ label: String, _ detail: String, share: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.dim)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            meter(share, color: color)
        }
    }

    private func meter(_ share: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 5)
    }

    private func figure(_ label: String, _ value: String?, note: String?, since: Date? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Palette.dim).frame(width: 34, alignment: .leading)
            if let since {
                Text(since, style: .relative)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            } else if let value {
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .contentTransition(.numericText())
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(Palette.dim)
            }
        }
    }

    /// A line over the last hour, filled in underneath, with the latest value.
    private func chart(_ label: String, _ points: [(Double, Double)], color: Color, unit: String, domain: ClosedRange<Double>) -> some View {
        let low = min(domain.lowerBound, (points.map(\.1).min() ?? domain.lowerBound) - 2)
        let high = max(domain.upperBound, (points.map(\.1).max() ?? domain.upperBound) + 2)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(Palette.dim).lineLimit(1)
                Spacer(minLength: 2)
                Text(points.last.map { "\(Int($0.1.rounded()))\(unit)" } ?? "-")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
            }
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", Date(timeIntervalSince1970: point.0)),
                             yStart: .value("Base", low), yEnd: .value(label, point.1))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: point.0)), y: .value(label, point.1))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: low...high)
            .frame(height: 36)
        }
        .frame(maxWidth: .infinity)
    }

    /// What's running, three to a row, green when up and red when not.
    private func servicesList(_ services: [ServerStats.Service]) -> some View {
        let shown = Array(services.prefix(6))
        let rows = stride(from: 0, to: shown.count, by: 3).map { Array(shown[$0..<min($0 + 3, shown.count)]) }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Running").font(.caption2).foregroundStyle(Palette.dim)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, service in
                        HStack(spacing: 5) {
                            Circle().fill(service.up ? Palette.good : Palette.bad).frame(width: 6, height: 6)
                            Text(service.name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(service.up ? Palette.text : Palette.dim)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<(3 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    // MARK: Numbers

    private var cpuText: String {
        stats?.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "-"
    }

    private var cpuColor: Color {
        Palette.level(stats?.cpuPercent ?? 0, warn: 60, bad: 85)
    }

    private var temperatureText: String {
        stats?.temperature.map { "\(Int($0.rounded()))°C" } ?? "-"
    }

    private var temperatureColor: Color {
        Palette.level(stats?.temperature ?? 0, warn: 65, bad: 75)
    }

    private func diskColor(_ disk: ServerStats.Disk) -> Color {
        Palette.level(disk.share, warn: 0.85, bad: 0.95)
    }
}
