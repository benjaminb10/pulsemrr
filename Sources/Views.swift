// The menu bar panel and the settings window.
import AppKit
import SwiftUI

enum Palette {
    static let money = Color(red: 0.11, green: 0.68, blue: 0.42)
    static let loss = Color(red: 0.88, green: 0.29, blue: 0.27)
    /// Opaque panel background: white in light mode, near black in dark mode.
    static let surface = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.11, alpha: 1) : .white })
    static let line = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07) })
}

struct MenuPanel: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isSnapshot) private var isSnapshot
    /// The header unfolds into today's figures project by project; remembered between openings.
    @AppStorage("todayOpen") private var todayOpen = false
    @State private var sectionsHeight: CGFloat = 600
    @AppStorage("quietOpen") private var quietOpen = false

    var body: some View {
        // The dashboard's look: white cards on a light grey background
        VStack(alignment: .leading, spacing: 10) {
            // The app's name, so the panel says what it is
            HStack(spacing: 7) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 18, height: 18)
                Text(verbatim: "PulseMRR").font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 6).padding(.top, 2)
            // Taller than the screen with many projects: the cards scroll, the name and the footer stay
            if isSnapshot { sections } else {
                ScrollView(.vertical, showsIndicators: false) {
                    sections.background(GeometryReader { g in Color.clear.preference(key: PanelHeight.self, value: g.size.height) })
                }
                .frame(height: min(sectionsHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 110))
                .onPreferenceChange(PanelHeight.self) { sectionsHeight = $0 }
            }
            footer.padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(10)
        .frame(width: 400)
        .task { if !isSnapshot { await model.refreshNotificationsAllowed() } }
        // A plain, opaque background: the menu's translucent material greys everything out.
        .background(Palette.canvas)
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.accounts.isEmpty {
                empty.padding(16).frame(maxWidth: .infinity, alignment: .leading).panelCard()
            } else {
                header.padding(16).panelCard()
                DashboardTeaser(model: model) { openDashboard(nil) }
                if !model.todos.isEmpty { TodoLine(model: model) }
                VStack(spacing: 0) {
                    HStack {
                        Text("Projects").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("MRR").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    let quiet = model.byTakings.filter(model.isQuiet)
                    let shown = model.byTakings.filter { !model.isQuiet($0) } + (quietOpen ? quiet : [])
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Hairline().padding(.leading, 54) }
                        ProjectRow(model: model, account: a)
                            .contentShape(Rectangle())
                            .onTapGesture { openDashboard(a.id) }
                            .help(String(localized: "Open this project in the dashboard"))
                    }
                    if !quiet.isEmpty {
                        Hairline().padding(.leading, 14)
                        QuietToggle(model: model, quiet: quiet, open: $quietOpen)
                            .font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .padding(.bottom, 4)
                .panelCard()
                ActivityList(model: model).padding(.top, 12).padding(.bottom, 6).panelCard()
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to PulseMRR").font(.headline)
            Text("Add a Stripe account to get a notification for every sale.").font(.callout).foregroundStyle(.secondary)
            Button("Add a Stripe account…") { openSettings() }
        }
    }

    /// One figure that matters, and one quiet line of context under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Today").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: todayOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Amount(model: model, sums: model.takings(0), font: .system(size: 32, weight: .semibold, design: .rounded))
            }
            HStack(spacing: 0) {
                stat("Yesterday") { Amount(model: model, sums: model.takings(1), font: .callout.weight(.semibold), compact: true, approxMark: false) }
                Rectangle().fill(Palette.line).frame(width: 1, height: 28).padding(.horizontal, 12)
                stat("New customers") { Text("\(model.newCustomers(0))").font(.callout.weight(.semibold)).monospacedDigit() }
                    .help(String(localized: "People who became Stripe customers today, trials included."))
                Rectangle().fill(Palette.line).frame(width: 1, height: 28).padding(.horizontal, 12)
                stat("MRR") { Amount(model: model, sums: model.mrrTotal, font: .callout.weight(.semibold), compact: true, approxMark: false) }
            }
            if todayOpen {
                Hairline()
                TodayBreakdown(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { todayOpen.toggle() } }
        .help(String(localized: todayOpen ? "Hide the detail by project" : "Show the detail by project"))
    }

    private func stat<V: View>(_ label: LocalizedStringKey, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var footer: some View {
        let content = HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise").onTapGesture { Task { await model.pollAll(); await model.refreshStats() } }.help("Refresh")
            Image(systemName: "bell").onTapGesture { model.replayRecent() }.help("Replay the latest notifications")
            if isSnapshot { Text("Checked") + Text(" ") + Text("4 s") }
            else if let t = model.lastPoll { Text("Checked") + Text(" ") + Text(t, style: .relative) }
            Spacer()
            if !model.notificationsAllowed {
                Image(systemName: "bell.slash").foregroundStyle(.orange)
                    .onTapGesture { model.openNotificationSettings() }
                    .help("Notifications are off for PulseMRR. Click to turn them on in System Settings.")
            }
            Image(systemName: "gearshape").onTapGesture { openSettings() }.help("Settings")
            Image(systemName: "power").onTapGesture { NSApp.terminate(nil) }.help("Quit PulseMRR")
        }
        content.font(.callout).foregroundStyle(.tertiary).contentShape(Rectangle())
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDashboard(_ project: UUID?) {
        // The Dashboard card keeps the ticked projects; a project's row opens on that project
        if let project { model.dashboardScope = project }
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PanelHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// The dashboard's card: white, rounded, with a hairline border.
    func panelCard() -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
}

/// The way into the dashboard: a card of its own under today's figure, with the MRR's last 12 months.
struct DashboardTeaser: View {
    @ObservedObject var model: Model
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let trend = model.mrrTrend()
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(LinearGradient(colors: [Palette.brand, Palette.mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dashboard").font(.subheadline.weight(.semibold))
                    Text("MRR, churn, best customers").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if trend.count > 1 && (trend.max() ?? 0) > 0 {
                    Sparkline(values: trend, color: Palette.brand, tip: String(localized: "MRR, last 12 months")).frame(width: 64, height: 24)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LinearGradient(colors: [Palette.brand.opacity(hover ? 0.13 : 0.08), Palette.mint.opacity(hover ? 0.11 : 0.06)],
                                       startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 12))
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.brand.opacity(0.22)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: .command)
        .onHover { hover = $0 }
        .help(String(localized: "Open the dashboard (⌘D)"))
    }
}

/// Sparkle's settings: daily automatic checks, and a button to check now.
struct UpdatesSettings: View {
    @State private var automatic = AppDelegate.updater?.updater.automaticallyChecksForUpdates ?? true
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        Toggle("Check for updates automatically", isOn: $automatic)
            .onChange(of: automatic) { AppDelegate.updater?.updater.automaticallyChecksForUpdates = $0 }
        HStack {
            Text(String(format: String(localized: "PulseMRR %@"), version)).foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates…") { AppDelegate.updater?.checkForUpdates(nil) }
                .disabled(AppDelegate.updater == nil)
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.line).frame(height: 1) }
}

/// Failed payments and disputes in one line; a click shows who, how much, and opens Stripe.
struct TodoLine: View {
    @ObservedObject var model: Model
    @State private var open = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let items = model.todos
        let total = items.reduce(0) { $0 + model.convert($1.amount, $1.currency) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Palette.loss)
                Text(String(format: String(localized: items.count > 1 ? "%lld failed payments" : "%lld failed payment"), items.count)).fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Text(Money.format(total, model.currency, compact: true)).foregroundStyle(Palette.loss).monospacedDigit()
                Spacer()
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
            if open || isSnapshot {
                ForEach(items.prefix(8)) { t in
                    HStack(spacing: 8) {
                        AccountIcon(model: model, account: t.account, size: 16)
                        Text(t.who ?? t.title).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Money.format(model.convert(t.amount, t.currency), model.currency, compact: true)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(t.url) }
                    .help("Open in Stripe")
                }
            }
        }
        .padding(4)
        .background(Palette.loss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.loss.opacity(0.18)))
    }
}

/// One project per row, no box: logo, name and a quiet line of signals, the 30-day sparkline, then MRR.
struct ProjectRow: View {
    @ObservedObject var model: Model
    let account: Account

    var body: some View {
        let d = model.mrrDetail[account.id]
        HStack(spacing: 12) {
            AccountIcon(model: model, account: account, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.callout.weight(.semibold)).lineLimit(1)
                detail(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Sparkline(values: model.month(account)).frame(width: 64, height: 22)
            VStack(alignment: .trailing, spacing: 1) {
                Amount(model: model, sums: model.mrr[account.id] ?? [:], font: .system(size: 15, weight: .semibold, design: .rounded), compact: true, dimZero: true, approxMark: false)
                Text("MRR").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .help(tooltip(d))
    }

    /// Everything about the project, for the hover: the details that don't fit on the line.
    private func tooltip(_ d: MrrSnapshot?) -> String {
        guard let d else { return account.name }
        var lines = [account.name + " · " + String(format: String(localized: d.activeCount > 1 ? "%lld subscribers" : "%lld subscriber"), d.activeCount)]
        if d.atRiskCount > 0 { lines.append(String(format: String(localized: d.atRiskCount > 1 ? "%lld failed payments" : "%lld failed payment"), d.atRiskCount) + " · " + Money.format(model.convert(d.atRisk), model.currency)) }
        if d.trialCount > 0 {
            var t = String(format: String(localized: d.trialCount > 1 ? "%lld trials" : "%lld trial"), d.trialCount)
            if let c = d.conversion { t += " · " + String(format: String(localized: "%lld %% of past trials became paying"), Int((c * 100).rounded())) }
            lines.append(t)
        }
        if d.leavingCount > 0 { lines.append(String(format: String(localized: d.leavingCount > 1 ? "%lld cancellations" : "%lld cancellation"), d.leavingCount)) }
        return lines.joined(separator: "\n")
    }

    /// Today first (sales, new customers), then this project's own signals, all on one line.
    private func detail(_ d: MrrSnapshot?) -> Text {
        var parts: [Text] = []
        let today = model.convert(model.takings(account, 0))
        if today > 0 { parts.append(Text("+" + Money.format(today, model.currency, compact: true)).foregroundColor(Palette.money).fontWeight(.medium)) }
        let n = model.newCustomers(account, 0)
        if n > 0 { parts.append(Text(Image(systemName: "person.fill")) + Text(" \(n)")) }
        if let d {
            if d.atRiskCount > 0 { parts.append(Text(String(format: String(localized: d.atRiskCount > 1 ? "%lld failed payments" : "%lld failed payment"), d.atRiskCount)).foregroundColor(Palette.loss)) }
            if d.trialCount > 0 { parts.append(Text(String(format: String(localized: d.trialCount > 1 ? "%lld trials" : "%lld trial"), d.trialCount))) }
            if d.leavingCount > 0 { parts.append(Text(String(format: String(localized: d.leavingCount > 1 ? "%lld cancellations" : "%lld cancellation"), d.leavingCount))) }
        }
        if let err = model.errors[account.id] { return Text(err).foregroundColor(.orange) }
        if parts.isEmpty { return Text("Quiet today") }
        parts = Array(parts.prefix(2))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ").foregroundColor(Color.secondary.opacity(0.5)) + $1 }
    }
}

/// 30 days of sales as a soft area with a line; today is the last point.
struct Sparkline: View {
    let values: [Int]
    var color: Color = Palette.money
    var tip = String(localized: "Sales, last 30 days")
    var body: some View {
        GeometryReader { geo in
            // Refund days below zero sit on the baseline
            let values = values.map { max($0, 0) }
            let top = CGFloat(max(values.max() ?? 0, 1)), w = geo.size.width, h = geo.size.height
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w
            let pts = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: h - 2 - CGFloat($0.element) / top * (h - 4)) }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first); pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = pts.last { Circle().fill(color).frame(width: 5, height: 5).position(last) }
            }
        }
        .help(tip)
    }
}

/// What the MRR figure leaves out, the way a founder reads it: failed payments, trials, the projection, churn on its way.
struct MrrBreakdown: View {
    @ObservedObject var model: Model
    var body: some View {
        let risk = model.atRiskTotal, trials = model.trialsTotal, leaving = model.leavingTotal
        let cur = model.currency
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
            if risk.count > 0 {
                chip("exclamationmark.triangle.fill", Palette.loss, String(localized: "At risk"), Money.format(risk.amount, cur, compact: true),
                     String(format: String(localized: "%lld subscriptions with a failed payment, not counted in the MRR. Stripe is still retrying."), risk.count))
            }
            if trials.count > 0 {
                let conv = model.conversionTotal.map { " · \(Int(($0 * 100).rounded())) %" } ?? ""
                chip("hourglass", .secondary, String(localized: "Trials"), Money.format(trials.amount, cur, compact: true) + conv,
                     String(format: String(localized: "%lld trials that will be charged at the end, and the share of past trials that became paying."), trials.count))
            }
            if let projected = model.projectedTotal, trials.count > 0 {
                chip("chart.line.uptrend.xyaxis", Palette.money, String(localized: "Projected"), Money.format(projected, cur, compact: true),
                     String(localized: "MRR + current trials × your real trial conversion rate."))
            }
            if leaving.count > 0 {
                chip("door.left.hand.open", .secondary, String(localized: "Leaving"), Money.format(leaving.amount, cur, compact: true),
                     String(format: String(localized: "%lld subscribers cancelled: still paying until the end of their period."), leaving.count))
            }
        }
    }

    private func chip(_ icon: String, _ tint: Color, _ title: String, _ value: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }
}

/// An amount in the display currency; "≈" and a tooltip with the original currencies when it was converted.
struct Amount: View {
    @ObservedObject var model: Model
    let sums: [String: Int]
    var font: Font = .body
    var compact = false
    var dimZero = false
    var approxMark = true

    var body: some View {
        let value = model.convert(sums)
        let converted = model.isConverted(sums)
        Text((converted && approxMark ? "≈ " : "") + (dimZero && value == 0 ? "–" : Money.format(value, model.currency, compact: compact)))
            .font(font).monospacedDigit()
            .foregroundStyle(dimZero && value == 0 ? .tertiary : .primary)
            .help(converted ? String(localized: "Converted at today's ECB rate:") + " " + Money.format(sums) : "")
            .lineLimit(1).minimumScaleFactor(approxMark ? 0.7 : 1).fixedSize(horizontal: !approxMark, vertical: false)
    }
}

struct Tile<Content: View>: View {
    let title: String
    let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Today against yesterday.
struct Delta: View {
    let today: Int, yesterday: Int
    var body: some View {
        if yesterday > 0 {
            let pct = Int((Double(today - yesterday) / Double(yesterday) * 100).rounded())
            Label("\(pct >= 0 ? "+" : "")\(pct) % " + String(localized: "vs yesterday"), systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(pct >= 0 ? Palette.money : Palette.loss)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((pct >= 0 ? Palette.money : Palette.loss).opacity(0.12), in: Capsule())
        }
    }
}

/// The last 7 days as bars, today in full colour.
struct WeekChart: View {
    @ObservedObject var model: Model
    var body: some View {
        let days = model.lastWeek
        let top = max(days.map(\.amount).max() ?? 0, 1)
        let f = DateFormatter()
        f.locale = Money.locale
        f.setLocalizedDateFormatFromTemplate("EEEEEE")
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                let isToday = i == days.count - 1
                VStack(spacing: 4) {
                    Text(isToday && d.amount > 0 ? Money.format(d.amount, model.currency, compact: true) : " ")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.money).lineLimit(1).fixedSize()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.money.opacity(isToday ? 1 : 0.35))
                        .frame(height: max(3, CGFloat(d.amount) / CGFloat(top) * 48))
                        .frame(maxHeight: 48, alignment: .bottom)
                        .help(Money.format(d.amount, model.currency))
                    Text(f.string(from: d.day).capitalized)
                        .font(.system(size: 9, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Today, yesterday and new customers for each project: what the header's totals are made of.
struct TodayBreakdown: View {
    @ObservedObject var model: Model
    @AppStorage("quietOpen") private var quietOpen = false
    var body: some View {
        let all = model.byTakings
        let quiet = all.filter(model.isQuiet)
        let rows = all.filter { !model.isQuiet($0) } + (quietOpen ? quiet : [])
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("Project").gridColumnAlignment(.leading)
                Text("Today")
                Text("Yesterday")
                Image(systemName: "person.fill").help(String(localized: "New customers"))
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
            ForEach(rows) { a in
                let today = model.convert(model.takings(a, 0)), n = model.newCustomers(a, 0)
                GridRow {
                    HStack(spacing: 7) {
                        AccountIcon(model: model, account: a, size: 16)
                        Text(a.name).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A refund can take the day below zero
                    Text(today > 0 ? "+" + Money.format(today, model.currency, compact: true) : today < 0 ? "−" + Money.format(-today, model.currency, compact: true) : "–")
                        .fontWeight(.semibold).foregroundStyle(today > 0 ? Palette.money : today < 0 ? Palette.loss : Color.secondary.opacity(0.5))
                    Amount(model: model, sums: model.takings(a, 1), font: .caption, compact: true, dimZero: true, approxMark: false)
                    Text(n > 0 ? "\(n)" : "–").foregroundStyle(n > 0 ? Color.primary : Color.secondary.opacity(0.5))
                }
                .font(.caption).monospacedDigit()
            }
            if !quiet.isEmpty {
                GridRow {
                    QuietToggle(model: model, quiet: quiet, open: $quietOpen, size: 16).gridCellColumns(4)
                }
                .font(.caption)
            }
        }
    }
}

/// The projects with nothing in 30 days, folded into one line; one that sells comes out by itself.
struct QuietToggle: View {
    @ObservedObject var model: Model
    let quiet: [Account]
    @Binding var open: Bool
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: -size * 0.3) {
                ForEach(quiet.prefix(5)) { a in AccountIcon(model: model, account: a, size: size) }
            }
            Text(String(format: String(localized: quiet.count > 1 ? "%lld quiet projects" : "%lld quiet project"), quiet.count))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
        .help(String(localized: "Nothing collected in 30 days, no MRR. A project that sells leaves this list by itself."))
    }
}

struct ActivityList: View {
    @ObservedObject var model: Model
    var body: some View {
        let items = Array(model.feed.prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            Text("Latest").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.bottom, 6)
            if items.isEmpty {
                Text("Nothing in the last 7 days.").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 6)
            }
            ForEach(items) { act in ActivityRow(model: model, act: act) }
        }
    }
}

struct ActivityRow: View {
    @ObservedObject var model: Model
    let act: Activity
    @State private var hover = false

    private var tone: Color {
        switch act.kind {
        case .sale, .newSubscriber, .trialConverted: return Palette.money
        case .refund, .paymentFailed, .dispute, .ended, .canceled: return Palette.loss
        default: return Color.secondary
        }
    }

    var body: some View {
        let account = model.accounts.first { $0.id == act.accountID }
        HStack(spacing: 10) {
            Circle().fill(tone).frame(width: 6, height: 6)
            if let account { AccountIcon(model: model, account: account, size: 18) }
            VStack(alignment: .leading, spacing: 0) {
                (Text(act.kind.label).fontWeight(.medium) + Text(act.who.map { "  " + ($0.components(separatedBy: " (").first ?? $0) } ?? "").foregroundColor(.secondary))
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                Text(act.created, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if let amount = act.amount, let cur = act.currency {
                let sign = [.sale, .newSubscriber, .trialConverted].contains(act.kind) ? "+" : (tone == Palette.loss ? "−" : "")
                // In the display currency, like everything else in the panel
                Text(sign + Money.format(model.convert(amount, cur), model.currency, compact: true)).font(.callout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(tone == Color.secondary ? Color.secondary : tone)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(hover ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(act.dashboardURL) }
        .help("Open in Stripe")
    }
}

/// The account's logo when there is one, else its emoji.
struct AccountIcon: View {
    @ObservedObject var model: Model
    let account: Account
    var size: CGFloat = 18

    var body: some View {
        if account.useLogo, let img = model.logos[account.id] {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Text(account.emoji).font(.system(size: size * 0.85)).frame(width: size, height: size)
        }
    }
}

/// A click on an account's icon: its logo, a short list of emojis, or the full macOS emoji picker.
struct IconPicker: View {
    @ObservedObject var model: Model
    @Binding var account: Account
    @Environment(\.dismiss) private var dismiss
    static let emojis = ["💰", "💳", "🚀", "⭐️", "🔥", "💎", "🎯", "📈", "🛍️", "🎓", "🎬", "🎵", "📚", "🧠", "🤝", "👑", "🇫🇷", "🌍", "🖥️", "📱", "🏠", "🍕", "🐶", "⚡️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let img = model.logos[account.id] {
                Button { account.useLogo = true; dismiss() } label: {
                    HStack {
                        Image(nsImage: img).resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Project logo")
                        Spacer()
                        if account.useLogo { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button { account.emoji = e; account.useLogo = false; dismiss() } label: {
                        Text(e).font(.system(size: 20)).frame(width: 30, height: 30)
                            .background((!account.useLogo && account.emoji == e) ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("More emojis…") {
                account.useLogo = false
                dismiss()
                NSApp.orderFrontCharacterPalette(nil)
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 290)
    }
}

struct AccountRow: View {
    @ObservedObject var model: Model
    @Binding var account: Account
    @State private var picking = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Button { picking = true } label: { AccountIcon(model: model, account: account, size: 26) }
                .buttonStyle(.plain).help("Change the icon")
                .popover(isPresented: $picking, arrowEdge: .bottom) { IconPicker(model: model, account: $account) }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $account.name).textFieldStyle(.plain).font(.body.weight(.medium)).labelsHidden()
                HStack(spacing: 6) {
                    if account.isRevenueCat {
                        Text(verbatim: "REVENUECAT").font(.caption2.bold()).foregroundStyle(Color(red: 0.95, green: 0.33, blue: 0.36))
                    } else {
                        Text(account.live ? "LIVE" : "TEST").font(.caption2.bold())
                            .foregroundStyle(account.live ? .green : .orange)
                    }
                    Text(account.isRevenueCat ? account.revenueCatProject : account.stripeID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let err = model.errors[account.id] { Text(err).font(.caption).foregroundStyle(.red).lineLimit(1).help(err) }
                }
            }
            Spacer()
            Toggle("", isOn: $account.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(account.enabled ? "Watched" : "Paused")
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this account")
                .confirmationDialog("Remove \(account.name)?", isPresented: $confirmDelete) {
                    Button("Remove", role: .destructive) { model.remove(account) }
                } message: { Text("Its key is deleted from the Keychain. You can add it back at any time.") }
        }
        .padding(.vertical, 4)
    }
}

/// Paste a key: PulseMRR finds the account's name and logo, you confirm.
struct AddAccountSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var connected = ""
    @State private var name = ""
    @State private var found: StripeClient.AccountInfo?
    @State private var logo: NSImage?
    @State private var busy = false
    @State private var error: String?
    @State private var advanced = false
    /// Mobile apps: a RevenueCat project instead of a Stripe account.
    @State private var revenueCat = false
    @State private var rcProject: RevenueCatClient.ProjectInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(revenueCat ? "Add RevenueCat apps" : "Add a Stripe account").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $revenueCat) {
                    Text(verbatim: "Stripe").tag(false)
                    Text(verbatim: "RevenueCat").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: revenueCat) { _ in key = ""; found = nil; rcProject = nil; error = nil }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.callout.weight(.medium))
                SecureField("", text: $key, prompt: Text(revenueCat ? "sk_…" : "rk_live_… or sk_live_…"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _ in found = nil; rcProject = nil; error = nil }
                Text(revenueCat ? "In RevenueCat: Project settings › API keys › New secret API key, version V2, with Read on Charts & metrics and on Project configuration."
                                : "In Stripe: Developers › API keys › Create restricted key, with Read on Events, Charges, Customers, Subscriptions and Payouts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !revenueCat {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    TextField("", text: $connected, prompt: Text("acct_… (connected account, for a Connect platform)"))
                        .textFieldStyle(.roundedBorder).padding(.top, 4)
                }
                .font(.callout)
            }

            if let rcProject {
                HStack(spacing: 10) {
                    Text("📱").font(.system(size: 26)).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("", text: $name, prompt: Text(rcProject.name)).textFieldStyle(.roundedBorder)
                        Text(verbatim: "RevenueCat · \(rcProject.id)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let found {
                HStack(spacing: 10) {
                    Group {
                        if let logo { Image(nsImage: logo).resizable().clipShape(RoundedRectangle(cornerRadius: 8)) }
                        else { Text("💳").font(.system(size: 26)) }
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("", text: $name, prompt: Text(found.name)).textFieldStyle(.roundedBorder)
                        Text("\(found.id) · \(found.currency.uppercased()) · \(found.live ? "live" : String(localized: "test mode"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }

            HStack {
                Text("The key stays in this Mac's Keychain. PulseMRR only reads.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if found == nil && rcProject == nil {
                    Button(busy ? "Checking…" : "Check") { check() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button(busy ? "Adding…" : "Add") { add() }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func check() {
        busy = true
        Task {
            if revenueCat {
                do {
                    rcProject = try await RevenueCatClient(key: key.trimmingCharacters(in: .whitespacesAndNewlines)).projects().first
                    if rcProject == nil { error = String(localized: "This key reads no project.") }
                    name = ""
                } catch { self.error = String(localized: "RevenueCat refused this key:") + " " + error.localizedDescription }
                busy = false
                return
            }
            do {
                let (info, img) = try await model.inspect(key: key, connected: connected.trimmingCharacters(in: .whitespaces))
                found = info; logo = img; name = ""
            } catch { self.error = String(localized: "Stripe refused this key:") + " " + error.localizedDescription }
            busy = false
        }
    }

    private func add() {
        busy = true
        Task {
            do {
                if revenueCat { try await model.addRevenueCat(key: key, name: name) }
                else { try await model.addAccount(name: name, emoji: "", key: key, connected: connected.trimmingCharacters(in: .whitespaces)) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                List {
                    ForEach($model.accounts) { $a in AccountRow(model: model, account: $a) }
                        .onMove { model.move(from: $0, to: $1) }
                }
                .frame(height: CGFloat(max(model.accounts.count, 1)) * 52)
                .scrollDisabled(true)
                Button { adding = true } label: { Label("Add an account…", systemImage: "plus") }
            } header: {
                Text("Stripe accounts")
            } footer: {
                Text("Drag an account to reorder. Click its icon to change it.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                ForEach(EventKind.allCases) { kind in
                    Toggle("\(kind.emoji)  \(kind.label)", isOn: Binding(
                        get: { model.prefs.kinds.contains(kind) },
                        set: { on in if on { model.prefs.kinds.insert(kind) } else { model.prefs.kinds.remove(kind) } }))
                }
                Toggle("Sound", isOn: $model.prefs.sound)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep notifications on screen")
                        Text("In System Settings, set PulseMRR's style to Persistent: each sale stays until you dismiss it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open…") { model.openNotificationSettings() }
                }
                Button("Replay the latest notifications") { model.replayRecent() }
            }

            Section("Daily recap") {
                Toggle("Send a recap of the day", isOn: $model.prefs.recapEnabled)
                Picker("At", selection: $model.prefs.recapHour) {
                    ForEach([12, 17, 18, 19, 20, 21, 22, 23], id: \.self) { Text("\($0):00").tag($0) }
                }
                .disabled(!model.prefs.recapEnabled)
                Button("Send the recap now") { Task { await model.refreshStats(); model.sendRecap() } }
            }

            Section("General") {
                Toggle("Today's amount in the menu bar", isOn: $model.prefs.showAmountInMenuBar)
                Toggle("Today's new customers in the menu bar", isOn: $model.prefs.showSignupsInMenuBar)
                Picker("Show amounts in", selection: $model.prefs.displayCurrency) {
                    Text("Euro (€)").tag("eur")
                    Text("US dollar ($)").tag("usd")
                    Text("Pound (£)").tag("gbp")
                    Text("Swiss franc (CHF)").tag("chf")
                    Text("Canadian dollar (CA$)").tag("cad")
                }
                Picker("Check every", selection: $model.prefs.pollSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section("Updates") {
                UpdatesSettings()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 660)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }
}
