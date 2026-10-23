import WidgetKit
import SwiftUI
import AppIntents
import Charts

/// The Pi at a glance on the home screen or lock screen: the Dashboard's
/// numbers from /api/widget/stats. iOS decides how often a widget may
/// refresh (every few minutes at best), so it asks every 5 minutes, the app
/// has it refresh whenever you leave it, and on iOS 17 the refresh button
/// does it at once. What's relative to now (how long ago, uptime) counts
/// on by itself in between. When the Pi doesn't answer it says so, and
/// tells that apart from the phone itself being offline.

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
                Image(systemName: reading.icon)
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

    private var reading: (share: Double, value: String, label: String, icon: String) {
        switch entry.state {
        case .serverDown: return (0, "off", "Pi", "exclamationmark.triangle.fill")
        case .noInternet: return (0, "-", "Pi", "wifi.slash")
        case .notConnected: return (0, "-", "Pi", icon)
        case .live: break
        }
        guard let stats = entry.stats else { return (0, "-", "Pi", icon) }
        switch metric {
        case .cpu:
            return (min(1, (stats.cpuPercent ?? 0) / 100), stats.cpuPercent.map { "\(Int($0.rounded()))" } ?? "-", "CPU", icon)
        case .temperature:
            return (min(1, (stats.temperature ?? 0) / 85), stats.temperature.map { "\(Int($0.rounded()))°" } ?? "-", "°C", icon)
        case .memory:
            return (stats.memory.share, "\(Int((stats.memory.share * 100).rounded()))", "RAM", icon)
        case .vault:
            let disk = stats.disks.first { $0.name == "Vault" } ?? stats.disks.last
            return (disk?.share ?? 0, disk.map { "\(Int(($0.share * 100).rounded()))" } ?? "-", "Vault", icon)
        }
    }
}

// MARK: - Data

struct StatsEntry: TimelineEntry {
    /// serverDown: the phone is online but the Pi doesn't answer.
    /// noInternet: the phone itself can't reach anything.
    enum State { case live, serverDown, noInternet, notConnected }
    let date: Date
    let stats: ServerStats?
    let state: State

    var isDown: Bool { state == .serverDown || state == .noInternet }
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
        } catch ServerStats.FetchError.rejected {
            // The token isn't the site's any more: the app gets a new one
            // next time it's opened (spa-shell.js).
            SharedStore.token = nil
            return StatsEntry(date: Date(), stats: nil, state: .notConnected)
        } catch ServerStats.FetchError.server(_) {
            // An answer, just not from the Pi (Cloudflare, nginx).
            return StatsEntry(date: Date(), stats: SharedStore.lastStats, state: .serverDown)
        } catch {
            // No answer at all: the Pi, or this phone's connection?
            let online = await ServerStats.internetReachable()
            return StatsEntry(date: Date(), stats: SharedStore.lastStats, state: online ? .serverDown : .noInternet)
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
    static let card = Color(red: 0x22 / 255, green: 0x1d / 255, blue: 0x19 / 255)
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

    @ViewBuilder private var rectangular: some View {
        if entry.isDown {
            VStack(alignment: .leading, spacing: 1) {
                Label(downTitle, systemImage: downIcon)
                    .font(.headline)
                if let stats {
                    (Text(entry.state == .serverDown ? "Last seen " : "Updated ") + Text(stats.at, style: .relative) + Text(" ago"))
                        .lineLimit(1)
                }
            }
            .widgetBackground()
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pi · \(temperatureText)")
                    .font(.headline)
                Text("CPU \(cpuText) · RAM \(stats.map { StatsFormat.percent($0.memory.share) } ?? "-")")
                if let vault {
                    Text("\(vault.name) \(StatsFormat.percent(vault.share)) full")
                }
            }
            .widgetBackground()
        }
    }

    private var inline: some View {
        Group {
            if entry.isDown {
                Label(downTitle, systemImage: downIcon)
            } else {
                Text("Pi \(temperatureText) · CPU \(cpuText)")
            }
        }
        .widgetBackground()
    }

    // MARK: Home screen

    /// Temperature up top, CPU as a big number with its last hour beside
    /// it, RAM and the Vault's free space as bars, network speed at the
    /// bottom.
    @ViewBuilder private var small: some View {
        if let stats, !entry.isDown {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(Palette.good).frame(width: 6, height: 6)
                    Text("Pi").font(.caption.weight(.semibold)).foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Image(systemName: "thermometer.medium").font(.caption2).foregroundStyle(temperatureColor)
                    Text(temperatureText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(temperatureColor)
                        .contentTransition(.numericText())
                }
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: -2) {
                        Text("CPU").font(.caption2).foregroundStyle(Palette.dim)
                        Text(cpuText)
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Palette.text)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if let points = cpuPoints(stats) {
                        sparkline(points, color: cpuColor, domain: cpuDomain(points))
                            .frame(height: 30)
                    }
                }
                compactBar("RAM", StatsFormat.percent(stats.memory.share), share: stats.memory.share, color: memoryColor(stats))
                if let vault {
                    compactBar(vault.name, StatsFormat.bytes(vault.total - vault.used) + " free", share: vault.share, color: diskColor(vault))
                }
                Text("↓ \(StatsFormat.speed(stats.network.down))  ↑ \(StatsFormat.speed(stats.network.up))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .widgetBackground()
        } else if entry.isDown {
            smallDown
        } else {
            notConnected
        }
    }

    /// The Pi (or the phone) offline: plainly, with when it was last heard
    /// from and what it said then.
    private var smallDown: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(downTitle, systemImage: downIcon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(downColor))
            if let stats {
                (Text(entry.state == .serverDown ? "Last seen " : "Updated ") + Text(stats.at, style: .relative) + Text(" ago"))
                    .font(.caption2)
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
            Text(entry.state == .serverDown ? "The Pi isn't answering." : "This phone is offline.")
                .font(.caption2)
                .foregroundStyle(Palette.dim)
            Spacer(minLength: 0)
            if let stats {
                Text("Last known").font(.system(size: 10)).foregroundStyle(Palette.dim)
                Text("CPU \(cpuText) · \(temperatureText)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text.opacity(0.7))
                if let vault {
                    Text("\(vault.name) \(StatsFormat.bytes(vault.total - vault.used)) free")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.text.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground()
    }

    /// CPU as a big number with its last hour, beside RAM and the disks.
    @ViewBuilder private var medium: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 10) {
                topLine
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU").font(.caption2).foregroundStyle(Palette.dim)
                        Text(cpuText)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Palette.text)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                        if let points = cpuPoints(stats) {
                            sparkline(points, color: cpuColor, domain: cpuDomain(points))
                                .frame(height: 24)
                        }
                        Text(stats.load.map { String(format: "Load %.2f", $0) } ?? "")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Palette.dim)
                    }
                    .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        bar("RAM", StatsFormat.bytes(stats.memory.used) + " of " + StatsFormat.bytes(stats.memory.total),
                            share: stats.memory.share, color: memoryColor(stats))
                        ForEach(stats.disks, id: \.name) { disk in
                            bar(disk.name, StatsFormat.bytes(disk.total - disk.used) + " free", share: disk.share, color: diskColor(disk))
                        }
                    }
                }
                .opacity(entry.isDown ? 0.4 : 1)
                footer(stats)
            }
            .widgetBackground()
        } else {
            notConnected
        }
    }

    /// Four figures up top, then the bars, the last hour and what's running.
    @ViewBuilder private var large: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 9) {
                topLine
                Group {
                    HStack(spacing: 7) {
                        statCard("CPU", cpuText, color: cpuColor)
                        statCard("Temp", temperatureText, color: temperatureColor)
                        statCard("Load", stats.load.map { String(format: "%.2f", $0) } ?? "-", color: Palette.text)
                        statCard("Up", uptimeText(stats), color: Palette.text)
                    }
                    bar("RAM", StatsFormat.bytes(stats.memory.used) + " of " + StatsFormat.bytes(stats.memory.total),
                        share: stats.memory.share, color: memoryColor(stats))
                    ForEach(stats.disks, id: \.name) { disk in
                        bar(disk.name, StatsFormat.bytes(disk.total - disk.used) + " free of " + StatsFormat.bytes(disk.total),
                            share: disk.share, color: diskColor(disk))
                    }
                    if let points = cpuPoints(stats) {
                        HStack(spacing: 14) {
                            chart("CPU, last hour", points, color: cpuColor, unit: "%", domain: cpuDomain(points))
                            if let temps = temperaturePoints(stats) {
                                chart("Temperature", temps, color: Palette.warn, unit: "°C", domain: 30...85)
                            }
                        }
                    }
                    if let services = stats.services, !services.isEmpty {
                        servicesList(services)
                    }
                }
                .opacity(entry.isDown ? 0.4 : 1)
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

    /// The name and temperature, or a banner saying it's offline.
    @ViewBuilder private var topLine: some View {
        if entry.isDown {
            HStack(spacing: 6) {
                Label(downTitle, systemImage: downIcon)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 4)
                Text(entry.state == .serverDown ? "The Pi isn't answering" : "This phone is offline")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(downColor))
        } else {
            HStack(spacing: 6) {
                Circle().fill(Palette.good).frame(width: 7, height: 7)
                Text("Raspberry Pi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Image(systemName: "thermometer.medium").font(.caption2).foregroundStyle(temperatureColor)
                Text(temperatureText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(temperatureColor)
                    .contentTransition(.numericText())
                    .padding(.trailing, 2)
                Text(stats?.name ?? "")
                    .font(.caption2)
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
        }
    }

    private func footer(_ stats: ServerStats) -> some View {
        HStack(spacing: 8) {
            if !entry.isDown {
                Label(StatsFormat.speed(stats.network.down), systemImage: "arrow.down")
                Label(StatsFormat.speed(stats.network.up), systemImage: "arrow.up")
            }
            Spacer(minLength: 0)
            (Text(entry.state == .serverDown ? "Last seen " : "") + Text(stats.at, style: .relative) + Text(" ago"))
                .foregroundStyle(entry.state == .serverDown ? Palette.text : Palette.dim)
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

    /// A labelled figure on a card, for the large widget's top row.
    private func statCard(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Palette.dim)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
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

    /// A bar with its label and value on one line above it, for the small widget.
    private func compactBar(_ label: String, _ value: String, share: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 2)
                Text(value)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.dim)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            meter(share, color: color, height: 4)
        }
    }

    private func meter(_ share: Double, color: Color, height: CGFloat = 5) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: height)
    }

    /// A line over the last hour, filled in underneath, with no labels.
    private func sparkline(_ points: [(Double, Double)], color: Color, domain: ClosedRange<Double>) -> some View {
        let low = min(domain.lowerBound, (points.map(\.1).min() ?? domain.lowerBound) - 2)
        let high = max(domain.upperBound, (points.map(\.1).max() ?? domain.upperBound) + 2)
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", Date(timeIntervalSince1970: point.0)),
                         yStart: .value("Base", low), yEnd: .value("Value", point.1))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", Date(timeIntervalSince1970: point.0)), y: .value("Value", point.1))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: low...high)
    }

    /// The last hour with what it shows and the latest value above it.
    private func chart(_ label: String, _ points: [(Double, Double)], color: Color, unit: String, domain: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(Palette.dim).lineLimit(1)
                Spacer(minLength: 2)
                Text(points.last.map { "\(Int($0.1.rounded()))\(unit)" } ?? "-")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
            }
            sparkline(points, color: color, domain: domain)
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

    private var vault: ServerStats.Disk? {
        stats.flatMap { s in s.disks.first { $0.name == "Vault" } ?? s.disks.last }
    }

    private var downTitle: String { entry.state == .serverDown ? "Server offline" : "No connection" }
    private var downIcon: String { entry.state == .serverDown ? "exclamationmark.triangle.fill" : "wifi.slash" }
    private var downColor: Color { entry.state == .serverDown ? Palette.bad : Palette.warn.opacity(0.85) }

    private func cpuPoints(_ stats: ServerStats) -> [(Double, Double)]? {
        let points = (stats.history ?? []).compactMap { p in p.cpu.map { (p.t, $0) } }
        return points.count >= 3 ? points : nil
    }

    private func temperaturePoints(_ stats: ServerStats) -> [(Double, Double)]? {
        let points = (stats.history ?? []).compactMap { p in p.temp.map { (p.t, $0) } }
        return points.count >= 3 ? points : nil
    }

    /// CPU use is mostly low, so its line is scaled to what it's been (to
    /// 25% at least) rather than to 100%, so its ups and downs show.
    private func cpuDomain(_ points: [(Double, Double)]) -> ClosedRange<Double> {
        0...max(25, (points.map(\.1).max() ?? 0) + 5)
    }

    private func uptimeText(_ stats: ServerStats) -> String {
        let hours = Int(stats.uptime / 3600)
        return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \(Int(stats.uptime / 60) % 60)m"
    }

    private var cpuText: String {
        stats?.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "-"
    }

    private var cpuColor: Color {
        Palette.level(stats?.cpuPercent ?? 0, warn: 60, bad: 85)
    }

    private func memoryColor(_ stats: ServerStats) -> Color {
        Palette.level(stats.memory.share, warn: 0.8, bad: 0.92)
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
