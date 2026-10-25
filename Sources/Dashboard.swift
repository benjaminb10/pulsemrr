// The dashboard window: MRR over time across projects, where it comes from and where it goes, takings,
// the goal, failed payments, best customers and the ones who left. Opened from the menu bar panel.
import AppKit
import Charts
import SwiftUI

extension Palette {
    static let brand = Color(red: 0.35, green: 0.31, blue: 0.88)
    static let mint = Color(red: 0.26, green: 0.75, blue: 0.53)
    static let warn = Color(red: 0.93, green: 0.58, blue: 0.13)
    /// Window background, a step below the cards.
    static let canvas = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.075, alpha: 1) : NSColor(white: 0.962, alpha: 1) })
    /// One colour per project in the charts, in the order of the accounts.
    static let projects: [Color] = [
        brand, mint, warn, Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.91, green: 0.33, blue: 0.56),
        Color(red: 0.08, green: 0.67, blue: 0.70), Color(red: 0.55, green: 0.36, blue: 0.85), Color(red: 0.55, green: 0.55, blue: 0.6),
    ]
}

struct DashboardView: View {
    @ObservedObject var model: Model

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 260, max: 320)
        } detail: {
            ScrollView {
                DashboardContent(model: model).padding(28).frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Period", selection: $model.dashboardMonths) {
                    Text("1 month").tag(1)
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                }
                .pickerStyle(.segmented)
                .help("Period shown in the charts")
                Button { Task { await model.loadDashboard(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.dashboardLoading)
                    .help("Read everything again from Stripe")
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .task { await model.loadDashboard() }
        .onAppear {
            model.dashboardOpen = true
            // A Dock icon and ⌘-Tab while the window is open, like a normal app
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // No blinking cursor in the goal field on opening
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        // Back to a menu bar app only when the window really closes: SwiftUI can call onDisappear when another app
        // takes the focus, and dropping the Dock icon then sent PulseMRR to the end of ⌘-Tab.
        .onDisappear { model.dashboardOpen = false }
    }
}

/// The projects with a tick each: all by default, any mix of them, or none.
struct DashboardSidebar: View {
    @ObservedObject var model: Model

    var body: some View {
        let all = model.dashboardAll, none = model.dashboardNone
        List {
            Section("Overview") {
                SidebarRow(checked: all, partly: !all && !none, onlyButton: false) {
                    Image(systemName: "square.grid.2x2").frame(width: 18).foregroundStyle(Palette.brand)
                } label: {
                    Text("All projects")
                } amount: {
                    Text(Fmt.money(model.active.reduce(0) { $0 + model.mrrNow($1) }, model)).foregroundStyle(.secondary).monospacedDigit()
                } toggle: {
                    model.toggleAllInDashboard()
                } only: {}
            }
            Section("Projects") {
                ForEach(model.byTakings) { a in
                    SidebarRow(checked: !model.dashboardExcluded.contains(a.id), partly: false, onlyButton: model.active.count > 1) {
                        AccountIcon(model: model, account: a, size: 18)
                    } label: {
                        Text(a.name).lineLimit(1)
                    } amount: {
                        Text(Fmt.money(model.mrrNow(a), model)).foregroundStyle(.secondary).monospacedDigit()
                    } toggle: {
                        model.toggleInDashboard(a.id)
                    } only: {
                        model.dashboardScope = a.id
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow<Icon: View, Label: View, Amount: View>: View {
    let checked: Bool
    let partly: Bool
    let onlyButton: Bool
    @ViewBuilder var icon: Icon
    @ViewBuilder var label: Label
    @ViewBuilder var amount: Amount
    let toggle: () -> Void
    let only: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.square.fill" : partly ? "minus.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(checked || partly ? Palette.brand : Color.secondary.opacity(0.6))
            icon
            label
            Spacer(minLength: 4)
            amount
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
        .opacity(checked || partly ? 1 : 0.55)
    }
}

struct DashboardContent: View {
    @ObservedObject var model: Model
    @Environment(\.isSnapshot) private var isSnapshot

    private var d: DashboardData { model.dashboard }
    private var project: Account? { model.dashboardScope.flatMap { id in model.active.first { $0.id == id } } }
    /// Several projects ticked, but not all of them.
    private var some: [Account]? { !model.dashboardAll && !model.dashboardNone && project == nil ? model.dashboardAccounts : nil }

    var body: some View {
        if model.dashboardNone && !model.active.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checklist.unchecked").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.brand)
                Text("Tick at least one project").font(.title3.weight(.semibold))
                Text("Pick the projects to add up in the sidebar, or tick All projects.").foregroundStyle(.secondary)
                Button("Tick all projects") { model.dashboardExcluded = [] }
                    .buttonStyle(.borderedProminent).tint(Palette.brand).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
        } else {
            filled
        }
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            KpiGrid(model: model)
            if project == nil { TodayCard(model: model) }
            // The goal is about the whole business
            if model.dashboardAll { GoalCard(model: model) }
            ProjectionSection(model: model)
            MrrChartCard(model: model)
            ChurnCard(model: model)
            Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                GridRow {
                    MovementsCard(model: model)
                    RevenueCard(model: model)
                }
                if project == nil {
                    GridRow {
                        ProjectsCard(model: model)
                        FailedCard(model: model)
                    }
                }
                GridRow {
                    CustomersCard(model: model)
                    ChurnedCard(model: model)
                }
                if project != nil {
                    GridRow { FailedCard(model: model).gridCellColumns(2) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let p = project {
                AccountIcon(model: model, account: p, size: 34)
            } else if let some {
                HStack(spacing: -8) {
                    ForEach(some.prefix(4)) { a in
                        AccountIcon(model: model, account: a, size: 30)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.canvas, lineWidth: 2))
                    }
                }
            } else {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 22)).foregroundStyle(Palette.brand)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? some.map { $0.count <= 2 ? $0.map(\.name).joined(separator: " + ") : Fmt.count($0.count, "%lld project", "%lld projects") } ?? String(localized: "All projects"))
                    .font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1)
                Group {
                    if isSnapshot { Text("Updated just now") }
                    else if model.dashboardLoading { Text("Reading Stripe…") }
                    else if let t = model.dashboardUpdated {
                        if Date().timeIntervalSince(t) < 60 { Text("Updated just now") }
                        else { Text("Updated") + Text(" ") + Text(RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date())) }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.dashboardLoading && !isSnapshot { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: building blocks

/// A white card with a title, an optional line under it, and anything on the right.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

@MainActor
enum Fmt {
    static func money(_ v: Int, _ model: Model, compact: Bool = true) -> String { Money.format(v, model.currency, compact: compact) }
    /// Axis labels: "−$2k" rather than "$-2k".
    static func axis(_ v: Int, _ model: Model) -> String { (v < 0 ? "−" : "") + Money.format(abs(v), model.currency, compact: true) }
    static func signed(_ v: Int, _ model: Model) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + Money.format(abs(v), model.currency, compact: true) }
    static func percent(_ v: Double?, digits: Int = 1) -> String {
        guard let v else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.locale = Money.locale
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "–"
    }
    static func signedPercent(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + percent(abs(v), digits: 0) }
    static func date(_ d: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = Money.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }
    static func count(_ n: Int, _ one: String.LocalizationValue, _ many: String.LocalizationValue) -> String {
        String(format: n > 1 ? String(localized: many) : String(localized: one), n)
    }
}

/// The y axis in compact money, the x axis in months.
private struct MoneyAxis: ViewModifier {
    let model: Model
    let months: Int
    func body(content: Content) -> some View {
        content
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                    AxisValueLabel { if let x = v.as(Double.self) { Text(Fmt.axis(Int(x), model)) } }
                }
            }
            .chartXAxis {
                // Over one month the axis counts weeks, not months
                if months <= 1 {
                    AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                    }
                } else {
                    AxisMarks(values: .stride(by: .month, count: months > 6 ? 2 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: false)
                    }
                }
            }
    }
}

// MARK: KPIs

struct KpiGrid: View {
    @ObservedObject var model: Model

    var body: some View {
        let d = model.dashboard
        let m30 = d.last30
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Kpi(title: "MRR", value: Fmt.money(d.mrr, model, compact: false),
                    note: d.growth.map { Text(Fmt.signedPercent($0)).foregroundColor(tone($0)) + Text(" ") + Text("in 30 days") },
                    help: String(localized: "Monthly recurring revenue from active subscriptions, at list price. Failed payments and trials don't count."))
                Kpi(title: String(localized: "Net new MRR"), value: Fmt.signed(m30.net, model),
                    note: Text(Fmt.signed(m30.new + m30.expansion + m30.reactivation, model)).foregroundColor(Palette.money) + Text("  ") + Text(Fmt.signed(-(m30.churn + m30.contraction), model)).foregroundColor(Palette.loss) + Text("  ·  ") + Text("30 days"),
                    help: String(localized: "New, upgraded and returning customers, minus the ones who left or pay less, over the last 30 days."))
                Kpi(title: String(localized: "Paying customers"), value: "\(d.customers)",
                    note: Text("+\(m30.newCustomers)").foregroundColor(Palette.money) + Text("  ") + Text("−\(m30.churnedCustomers)").foregroundColor(Palette.loss) + Text("  ·  ") + Text("30 days"),
                    help: String(localized: "Customers with at least one paying subscription."))
                Kpi(title: String(localized: "Revenue per customer"), value: Fmt.money(d.arpu, model, compact: false),
                    note: Text("a month (ARPU)"),
                    help: String(localized: "MRR divided by paying customers."))
            }
            GridRow {
                Kpi(title: String(localized: "Customer churn"), value: Fmt.percent(d.customerChurn),
                    note: Text(String(format: String(localized: "%lld of %lld left in 30 days"), m30.churnedCustomers, m30.startCustomers)),
                    help: String(localized: "Share of the customers paying 30 days ago who no longer pay."))
                Kpi(title: String(localized: "Revenue churn"), value: Fmt.percent(d.revenueChurn),
                    note: Text(Fmt.money(m30.churn + m30.contraction, model)) + Text(" ") + Text("lost in 30 days"),
                    help: String(localized: "MRR lost to cancellations and downgrades in 30 days, against the MRR of 30 days ago."))
                Kpi(title: String(localized: "Lifetime value"), value: d.ltv.map { Fmt.money($0, model) } ?? "–",
                    note: Text("ARPU ÷ monthly churn"),
                    help: String(localized: "What a customer brings in over their whole time with you: revenue per customer divided by the monthly customer churn of the last 90 days."))
                Kpi(title: String(localized: "Trial conversion"), value: Fmt.percent(d.trialConversion, digits: 0),
                    note: Text(Fmt.count(d.trialsEnded, "of %lld trial ended in 90 days", "of %lld trials ended in 90 days")),
                    help: String(localized: "Trials that ended in the last 90 days and became paying."))
            }
        }
    }

    private func tone(_ v: Double) -> Color { v > 0 ? Palette.money : v < 0 ? Palette.loss : .secondary }
}

struct Kpi: View {
    let title: String
    let value: String
    let note: Text?
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            (note ?? Text(" ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
        .help(help)
    }
}

// MARK: MRR over time

struct MrrChartCard: View {
    @ObservedObject var model: Model
    @State private var hover: Date?

    var body: some View {
        let d = model.dashboard
        let accounts = model.dashboardAccounts
        let dates = Array(Set(d.series.map(\.date))).sorted()
        let at = hover.flatMap { h in dates.min { abs($0.timeIntervalSince(h)) < abs($1.timeIntervalSince(h)) } }
        let shown = at ?? dates.last
        let total = d.series.filter { $0.date == shown }.reduce(0) { $0 + $1.value }
        let first = d.series.filter { $0.date == dates.first }.reduce(0) { $0 + $1.value }
        let names = accounts.map(\.name)
        let colors = accounts.map { color(for: $0) }
        Card(title: "MRR", subtitle: subtitle(first: first, last: d.mrr)) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.money(total, model, compact: false)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(shown.map { Fmt.date($0, "d MMM yyyy") } ?? "").font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            Chart {
                ForEach(d.series) { p in
                    AreaMark(x: .value("Date", p.date), y: .value("MRR", Double(p.value)), stacking: .standard)
                        .foregroundStyle(by: .value("Project", name(p.account, accounts)))
                        .interpolationMethod(.monotone)
                        .opacity(0.85)
                }
                if let at {
                    RuleMark(x: .value("Date", at)).foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(accounts.count > 1 ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading)
            .modifier(MoneyAxis(model: model, months: model.dashboardMonths))
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): hover = proxy.value(atX: loc.x - geo[proxy.plotAreaFrame].origin.x, as: Date.self)
                            case .ended: hover = nil
                            }
                        }
                }
            }
            .frame(height: 250)
            if let at, accounts.count > 1 {
                HStack(spacing: 14) {
                    ForEach(accounts) { a in
                        let v = d.series.first { $0.date == at && $0.account == a.id }?.value ?? 0
                        HStack(spacing: 5) {
                            Circle().fill(color(for: a)).frame(width: 7, height: 7)
                            Text(a.name).foregroundStyle(.secondary)
                            Text(Fmt.money(v, model)).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private func subtitle(first: Int, last: Int) -> String {
        let period = model.dashboardMonths == 1 ? String(localized: "Last 30 days")
            : String(format: String(localized: "Last %lld months"), model.dashboardMonths)
        guard first > 0 else { return period }
        return period + " · " + Fmt.signedPercent(Double(last - first) / Double(first))
    }

    private func name(_ id: UUID, _ accounts: [Account]) -> String { accounts.first { $0.id == id }?.name ?? "" }

    func color(for a: Account) -> Color {
        if model.dashboardScope != nil { return Palette.brand }
        let i = model.active.firstIndex(of: a) ?? 0
        return Palette.projects[i % Palette.projects.count]
    }
}

// MARK: MRR movements

struct MovementsCard: View {
    @ObservedObject var model: Model
    @State private var hover: Date?

    var body: some View {
        let months = model.dashboard.months
        let kinds: [(String, Color)] = [
            (String(localized: "New"), Palette.money), (String(localized: "Expansion"), Palette.mint),
            (String(localized: "Reactivation"), Color(red: 0.08, green: 0.67, blue: 0.70)),
            (String(localized: "Contraction"), Palette.warn), (String(localized: "Churn"), Palette.loss),
        ]
        let current = months.last?.move ?? Movement()
        let weekly = model.dashboardMonths <= 1
        let unit: Calendar.Component = weekly ? .weekOfYear : .month
        Card(title: String(localized: "MRR movements"),
             subtitle: weekly ? String(localized: "What moved the MRR, week by week") : String(localized: "What moved the MRR, month by month")) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.signed(current.net, model)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(current.net >= 0 ? Palette.money : Palette.loss)
                Text(weekly ? "this week" : "this month").font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            Chart {
                ForEach(months) { m in
                    let parts = [m.move.new, m.move.expansion, m.move.reactivation, -m.move.contraction, -m.move.churn]
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, v in
                        if v != 0 {
                            BarMark(x: .value("Month", m.month, unit: unit), y: .value("MRR", Double(v)), width: .ratio(0.62))
                                .foregroundStyle(by: .value("Kind", kinds[i].0))
                        }
                    }
                }
                ForEach(months) { m in
                    LineMark(x: .value("Month", m.month, unit: unit), y: .value("Net", Double(m.move.net)))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .symbol(Circle().strokeBorder(lineWidth: 1.5))
                        .symbolSize(22)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Palette.line)
                if let h = hover, let m = months.last(where: { $0.month <= h }) {
                    let mid = months[months.count / 2].month
                    RuleMark(x: .value("Month", m.month, unit: unit))
                        .foregroundStyle(Color.primary.opacity(0.07)).lineStyle(StrokeStyle(lineWidth: 26))
                        .annotation(position: m.month > mid ? .leading : .trailing, alignment: .top, spacing: 10) {
                            ChartTip(title: weekly ? String(format: String(localized: "Week of %@"), Fmt.date(m.month, "d MMMM")) : Fmt.date(m.month, "MMMM yyyy"), rows: [
                                (Palette.money, kinds[0].0, Fmt.signed(m.move.new, model)),
                                (Palette.mint, kinds[1].0, Fmt.signed(m.move.expansion, model)),
                                (kinds[2].1, kinds[2].0, Fmt.signed(m.move.reactivation, model)),
                                (Palette.warn, kinds[3].0, Fmt.signed(-m.move.contraction, model)),
                                (Palette.loss, kinds[4].0, Fmt.signed(-m.move.churn, model)),
                                (Color.primary.opacity(0.7), String(localized: "Net"), Fmt.signed(m.move.net, model)),
                            ])
                        }
                }
            }
            .modifier(HoverDate(hover: $hover))
            .chartForegroundStyleScale(domain: kinds.map(\.0), range: kinds.map(\.1))
            .chartLegend(position: .bottom, alignment: .leading)
            .modifier(MoneyAxis(model: model, months: model.dashboardMonths))
            .frame(height: 230)
            .help(String(localized: "Bars: new, upgraded and returning customers above zero, downgrades and cancellations below. Line: the net change."))
        }
    }
}

// MARK: Revenue collected

struct RevenueCard: View {
    @ObservedObject var model: Model
    @State private var picked: Calendar.Component = .month
    /// Over a single month, months would be one bar: days instead
    private var unit: Calendar.Component { model.dashboardMonths <= 1 && picked == .month ? .day : picked }
    @State private var hover: Date?
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let accounts = model.dashboardAccounts
        let buckets = self.buckets(accounts)
        let total = buckets.reduce(0) { $0 + $1.value }
        Card(title: String(localized: "Revenue collected"), subtitle: comparison) {
            if isSnapshot {
                Text(label(unit)).font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $picked) {
                    Text("Days").tag(Calendar.Component.day)
                    Text("Weeks").tag(Calendar.Component.weekOfYear)
                    Text("Months").tag(Calendar.Component.month)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: model.dashboardMonths) { m in if m <= 1 && picked == .month { picked = .day } }
            }
        } content: {
            Chart {
                ForEach(buckets) { b in
                    BarMark(x: .value("Date", b.date, unit: unit), y: .value("Revenue", Double(b.value)))
                        .foregroundStyle(by: .value("Project", b.name))
                        .cornerRadius(2)
                }
                if let h = hover, let key = Calendar.current.dateInterval(of: unit, for: h)?.start {
                    let here = buckets.filter { $0.date == key }
                    let dates = Array(Set(buckets.map(\.date))).sorted()
                    let mid = dates.isEmpty ? key : dates[dates.count / 2]
                    RuleMark(x: .value("Date", key, unit: unit))
                        .foregroundStyle(Color.primary.opacity(0.07)).lineStyle(StrokeStyle(lineWidth: unit == .day ? 8 : 26))
                        .annotation(position: key > mid ? .leading : .trailing, alignment: .top, spacing: 10) {
                            ChartTip(title: Fmt.date(key, unit == .month ? "MMMM yyyy" : "d MMM yyyy"),
                                     rows: here.map { b in (color(accounts.first { $0.name == b.name } ?? accounts[0]), b.name, Fmt.money(b.value, model)) }
                                        + [(Color.primary.opacity(0.7), String(localized: "Total"), Fmt.money(here.reduce(0) { $0 + $1.value }, model))])
                        }
                }
            }
            .modifier(HoverDate(hover: $hover))
            .chartForegroundStyleScale(domain: accounts.map(\.name), range: accounts.map(color))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                    AxisValueLabel { if let x = v.as(Double.self) { Text(Fmt.axis(Int(x), model)) } }
                }
            }
            .frame(height: 230)
            Text(String(localized: "Total shown") + " · " + Fmt.money(total, model, compact: false)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private struct Bucket: Identifiable { let date: Date; let name: String; let value: Int; var id: String { name + "\(date.timeIntervalSince1970)" } }

    private func buckets(_ accounts: [Account]) -> [Bucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from: Date
        switch unit {
        case .day: from = cal.date(byAdding: .day, value: -29, to: today)!
        case .weekOfYear: from = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: -11, to: today)!)!.start
        default: from = cal.date(byAdding: .month, value: -(model.dashboardMonths - 1), to: cal.dateInterval(of: .month, for: today)!.start)!
        }
        var sums: [Date: [UUID: Int]] = [:]
        for (day, per) in model.dashboard.revenue where day >= from {
            let key = cal.dateInterval(of: unit, for: day)!.start
            for (id, v) in per { sums[key, default: [:]][id, default: 0] += v }
        }
        return sums.flatMap { date, per in accounts.compactMap { a in per[a.id].map { Bucket(date: date, name: a.name, value: $0) } } }
            .sorted { $0.date < $1.date }
    }

    /// This month so far against the same days of last month.
    private var comparison: String {
        let cal = Calendar.current
        let now = Date()
        let start = cal.dateInterval(of: .month, for: now)!.start
        let prevStart = cal.date(byAdding: .month, value: -1, to: start)!
        let prevEnd = cal.date(byAdding: .month, value: -1, to: now)!
        var this = 0, prev = 0
        for (day, per) in model.dashboard.revenue {
            let v = per.values.reduce(0, +)
            if day >= start { this += v } else if day >= prevStart && day <= prevEnd { prev += v }
        }
        var s = String(localized: "This month") + " " + Fmt.money(this, model)
        if prev > 0 { s += " · " + Fmt.signedPercent(Double(this - prev) / Double(prev)) + " " + String(localized: "vs the same days last month") }
        return s
    }

    private func label(_ u: Calendar.Component) -> String {
        switch u {
        case .day: return String(localized: "Days")
        case .weekOfYear: return String(localized: "Weeks")
        default: return String(localized: "Months")
        }
    }

    private func color(_ a: Account) -> Color {
        if model.dashboardScope != nil { return Palette.money }
        let i = model.active.firstIndex(of: a) ?? 0
        return Palette.projects[i % Palette.projects.count]
    }
}

// MARK: Goal

struct GoalCard: View {
    @ObservedObject var model: Model
    @State private var draft = ""
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let d = model.dashboard
        let goal = model.prefs.goal * 100
        Card(title: String(localized: "MRR goal"), subtitle: goal > 0 ? nil : String(localized: "Set a target to see when you'll reach it")) {
            if isSnapshot {
                Text(goal > 0 ? Fmt.money(goal, model) : "").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    TextField(String(localized: "Goal"), text: $draft)
                        .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                        .onSubmit { save() }
                    Text(model.currency.uppercased()).font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { draft = model.prefs.goal > 0 ? "\(model.prefs.goal)" : "" }
            }
        } content: {
            if goal > 0 {
                let share = min(1, Double(d.mrr) / Double(goal))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.money(d.mrr, model, compact: false)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(String(localized: "of") + " " + Fmt.money(goal, model, compact: false)).foregroundStyle(.secondary)
                        Text(Fmt.percent(share, digits: 0)).fontWeight(.semibold).foregroundStyle(Palette.brand).monospacedDigit()
                        Spacer(minLength: 12)
                        Text(eta(d, goal)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.line)
                            Capsule().fill(LinearGradient(colors: [Palette.brand, Palette.mint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(8, geo.size.width * share))
                        }
                    }
                    .frame(height: 10)
                }
            } else {
                Text("Type a monthly revenue target, for example 10000, and press Return.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func eta(_ d: DashboardData, _ goal: Int) -> String {
        if d.mrr >= goal { return String(localized: "Goal reached. Time for the next one.") }
        guard let pace = d.pace, pace > 0 else {
            return String(localized: "The MRR hasn't grown over the last 3 months, so there's no date to show yet.")
        }
        let months = Int((Double(goal - d.mrr) / Double(pace)).rounded(.up))
        let date = Calendar.current.date(byAdding: .month, value: months, to: Date())!
        return String(format: String(localized: "At %@ a month (the average of the last 3 months), you'd get there in %@."),
                      Fmt.signed(pace, model), Fmt.date(date, "MMMM yyyy"))
    }

    private func save() {
        let digits = draft.filter(\.isNumber)
        model.prefs.goal = Int(digits) ?? 0
        draft = model.prefs.goal > 0 ? "\(model.prefs.goal)" : ""
    }
}

// MARK: Failed payments

struct FailedCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let all = model.dashboard.failed
        let retrying = sum(.retrying), recovered = sum(.recovered), lost = sum(.lost)
        let decided = recovered.0 + lost.0
        Card(title: String(localized: "Failed payments"),
             subtitle: decided > 0 ? String(format: String(localized: "%@ recovered in the last 90 days"), Fmt.percent(Double(recovered.0) / Double(decided), digits: 0))
                                   : String(localized: "Last 90 days")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    stat(String(localized: "Retrying"), retrying, Palette.warn)
                    stat(String(localized: "Recovered"), recovered, Palette.money)
                    stat(String(localized: "Lost"), lost, Palette.loss)
                }
                let open = all.filter { $0.invoice.state == .retrying }.prefix(5)
                if all.isEmpty {
                    Text("No failed payment in the last 90 days.").font(.callout).foregroundStyle(.secondary)
                } else if !open.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(open)) { f in
                            PersonRow(model: model, account: f.account, who: f.invoice.who ?? f.invoice.id,
                                      detail: Fmt.date(f.invoice.created, "d MMM"), amount: Fmt.money(f.amount, model), tone: Palette.warn)
                                .onTapGesture { NSWorkspace.shared.open(f.invoice.url) }
                                .help(String(localized: "Open in Stripe"))
                        }
                    }
                }
            }
        }
    }

    private func sum(_ s: FailedInvoice.State) -> (Int, Int) {
        let f = model.dashboard.failed.filter { $0.invoice.state == s }
        return (f.reduce(0) { $0 + $1.amount }, f.count)
    }

    private func stat(_ title: String, _ v: (Int, Int), _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(Fmt.money(v.0, model)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(Fmt.count(v.1, "%lld invoice", "%lld invoices")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: People

/// One line about a customer: project icon, name, a quiet detail, an amount.
struct PersonRow: View {
    @ObservedObject var model: Model
    let account: UUID
    let who: String
    let detail: String
    let amount: String
    var tone: Color = .primary
    var rank: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let rank { Text("\(rank)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 14, alignment: .trailing).monospacedDigit() }
            if let a = model.accounts.first(where: { $0.id == account }) { AccountIcon(model: model, account: a, size: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(who).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(amount).fontWeight(.medium).foregroundStyle(tone).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct CustomersCard: View {
    @ObservedObject var model: Model
    var body: some View {
        let top = model.dashboard.top
        Card(title: String(localized: "Best customers"), subtitle: String(localized: "By MRR, today")) {
            if top.isEmpty { Text("No paying customer yet.").font(.callout).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Hairline() }
                    PersonRow(model: model, account: p.account, who: p.who,
                              detail: String(localized: "Customer since") + " " + Fmt.date(p.date, "MMM yyyy"),
                              amount: Fmt.money(p.mrr, model), rank: i + 1)
                }
            }
        }
    }
}

struct ChurnedCard: View {
    @ObservedObject var model: Model
    var body: some View {
        let gone = model.dashboard.churned
        Card(title: String(localized: "Who left"), subtitle: String(localized: "Last 90 days, latest first")) {
            if gone.isEmpty { Text("Nobody left in the last 90 days.").font(.callout).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(Array(gone.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Hairline() }
                    PersonRow(model: model, account: p.account, who: p.who, detail: Fmt.date(p.date, "d MMM yyyy"),
                              amount: "−" + Fmt.money(p.mrr, model), tone: Palette.loss)
                }
            }
        }
    }
}

// MARK: Projects

struct ProjectsCard: View {
    @ObservedObject var model: Model
    var body: some View {
        // Already in the panel's order: most money first
        let rows = model.dashboard.projects
        Card(title: String(localized: "Projects"), subtitle: String(localized: "Last 30 days. Click one to open it.")) {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("Project").gridColumnAlignment(.leading)
                    Text("MRR"); Text("30 days"); Text("Customers"); Text("ARPU"); Text("Churn")
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
                ForEach(rows) { r in
                    if let a = model.active.first(where: { $0.id == r.id }) {
                        Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                        GridRow {
                            HStack(spacing: 8) {
                                AccountIcon(model: model, account: a, size: 20)
                                Text(a.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridColumnAlignment(.leading)
                            Text(Fmt.money(r.mrr, model)).fontWeight(.medium)
                            Text(r.growth.map(Fmt.signedPercent) ?? "–")
                                .foregroundStyle(r.growth.map { $0 > 0 ? Palette.money : $0 < 0 ? Palette.loss : .secondary } ?? .secondary)
                            Text("\(r.customers)")
                            Text(Fmt.money(r.arpu, model)).foregroundStyle(.secondary)
                            Text(Fmt.percent(r.churn)).foregroundStyle(.secondary)
                        }
                        .font(.callout).monospacedDigit()
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { model.dashboardScope = a.id }
                        .help(String(localized: "Show only this project"))
                    }
                }
            }
        }
    }
}

// MARK: Today

/// Today's takings, yesterday's and today's new customers, project by project: the menu bar panel's figures, broken down.
struct TodayCard: View {
    @ObservedObject var model: Model
    var body: some View {
        let accounts = model.dashboardAccounts
        let rows = model.byTakings.filter { a in accounts.contains { $0.id == a.id } }
        let today = accounts.reduce(0) { $0 + model.convert(model.takings($1, 0)) }
        let yesterday = accounts.reduce(0) { $0 + model.convert(model.takings($1, 1)) }
        let signups = accounts.reduce(0) { $0 + model.newCustomers($1, 0) }
        Card(title: String(localized: "Today"), subtitle: String(localized: "Takings and new customers, by project. Click one to open it.")) {
            Delta(today: today, yesterday: yesterday)
        } content: {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("Project").gridColumnAlignment(.leading)
                    Text("Today"); Text("Yesterday"); Text("New customers")
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
                ForEach(rows) { a in
                    let t = model.convert(model.takings(a, 0)), y = model.convert(model.takings(a, 1)), n = model.newCustomers(a, 0)
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                    GridRow {
                        HStack(spacing: 8) {
                            AccountIcon(model: model, account: a, size: 20)
                            Text(a.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                        figure(t, plus: true).fontWeight(.semibold)
                        figure(y)
                        Text(n > 0 ? "\(n)" : "–").foregroundStyle(n > 0 ? Color.primary : Color.secondary.opacity(0.5))
                    }
                    .font(.callout).monospacedDigit()
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { model.dashboardScope = a.id }
                    .help(String(localized: "Show only this project"))
                }
                if rows.count > 1 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Total").fontWeight(.semibold).gridColumnAlignment(.leading)
                        figure(today, plus: true).fontWeight(.bold)
                        figure(yesterday).fontWeight(.semibold)
                        Text("\(signups)").fontWeight(.semibold)
                    }
                    .font(.callout).monospacedDigit()
                    .padding(.top, 8)
                }
            }
        }
    }

    private func figure(_ v: Int, plus: Bool = false) -> some View {
        Text(v > 0 ? (plus ? "+" : "") + Fmt.money(v, model, compact: false) : v < 0 ? "−" + Fmt.money(-v, model, compact: false) : "–")
            .foregroundStyle(v > 0 ? (plus ? Palette.money : Color.primary) : v < 0 ? Palette.loss : Color.secondary.opacity(0.5))
    }
}

// MARK: Trials and projection

/// The real MRR of the last 30 days and where the running trials take it, with the side figures.
struct ProjectionSection: View {
    @ObservedObject var model: Model

    var body: some View {
        let p = model.projection
        HStack(alignment: .top, spacing: 18) {
            ProjectionChartCard(model: model, p: p)
            VStack(spacing: 14) {
                SideStat(title: String(localized: "Projection at the real conversion rate"), value: Fmt.money(p.projected, model, compact: false),
                         note: p.rate.map { String(format: String(localized: "%@ + %@ of %@ in trials"), Fmt.money(p.real, model), Fmt.percent($0, digits: 0), Fmt.money(p.trials, model)) }
                            ?? String(localized: "No trial has ended yet"),
                         tint: Palette.brand)
                HStack(spacing: 14) {
                    SideStat(title: String(localized: "In trial"), value: Fmt.money(p.trials, model),
                             note: Fmt.count(p.trialCount, "%lld trial", "%lld trials") + (p.trialsCancelling > 0 ? " · " + String(format: String(localized: "%lld cancelling"), p.trialsCancelling) : ""))
                    SideStat(title: String(localized: "At risk"), value: Fmt.money(p.atRisk, model),
                             note: Fmt.count(p.atRiskCount, "%lld failed payment", "%lld failed payments"), tint: p.atRisk > 0 ? Palette.warn : nil)
                }
                EndedTrialsCard(model: model, p: p)
            }
            .frame(width: 320)
        }
    }
}

struct SideStat: View {
    let title: String
    let value: String
    let note: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint ?? .primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }
}

/// Ended trials, one outcome per customer: paying, payment failed, cancelled.
struct EndedTrialsCard: View {
    @ObservedObject var model: Model
    let p: Projection

    var body: some View {
        let parts: [(String, Int, Color)] = [
            (String(localized: "Paying"), p.endedPaying, Palette.money),
            (String(localized: "Payment failed"), p.endedFailed, Palette.warn),
            (String(localized: "Cancelled"), p.endedCancelled, Palette.loss),
        ]
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.count(p.ended, "Ended trials (%lld customer)", "Ended trials (%lld customers)")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text("Where they stand today. The projection uses this paying share.").font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        if parts[i].1 > 0 {
                            Rectangle().fill(parts[i].2).frame(width: max(2, geo.size.width * CGFloat(parts[i].1) / CGFloat(max(p.ended, 1)) - 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .background(Capsule().fill(Palette.line))
            VStack(spacing: 5) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 7) {
                        Circle().fill(parts[i].2).frame(width: 7, height: 7)
                        Text(parts[i].0)
                        Spacer()
                        Text("\(parts[i].1)").fontWeight(.semibold).monospacedDigit()
                        Text(Fmt.percent(p.ended > 0 ? Double(parts[i].1) / Double(p.ended) : nil, digits: 0))
                            .foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }
}

struct ProjectionChartCard: View {
    @ObservedObject var model: Model
    let p: Projection
    @State private var hover: Date?

    /// The day under the mouse.
    private var picked: Projection.Day? {
        guard let h = hover else { return nil }
        return p.days.min { abs($0.date.addingTimeInterval(43200).timeIntervalSince(h)) < abs($1.date.addingTimeInterval(43200).timeIntervalSince(h)) }
    }

    private func tip(_ d: Projection.Day) -> ChartTip {
        var rows: [(Color, String, String)] = []
        if let v = d.real { rows.append((Palette.brand, String(localized: "Real MRR"), Fmt.money(v, model))) }
        if d.real == nil || d.date == p.days.first(where: { $0.all != nil })?.date {
            if let v = d.all { rows.append((Palette.brand.opacity(0.6), String(localized: "If every trial pays"), Fmt.money(v, model))) }
            if let v = d.atRate { rows.append((Palette.mint, String(localized: "At the real conversion rate"), Fmt.money(v, model))) }
        }
        if d.real != nil {
            rows.append((Palette.money, String(localized: "New paying customers"), "\(d.newPaying)"))
            rows.append((Color(red: 0.62, green: 0.68, blue: 0.82), String(localized: "New trials"), "\(d.newTrials)"))
            rows.append((Palette.loss, String(localized: "Trials cancelled"), "\(d.cancelledTrials)"))
        }
        return ChartTip(title: Fmt.date(d.date, "EEEE d MMM"), rows: rows)
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let first = p.days.first?.date ?? today
        let last = (p.days.last?.date ?? today).addingTimeInterval(86400)
        Card(title: String(localized: "Real MRR and trials"), subtitle: String(localized: "Last 30 days, and where the running trials lead")) {
            HStack(spacing: 8) {
                if let ago = p.real7Ago { pill(Fmt.signed(p.real - ago, model), String(localized: "7 days"), (p.real - ago) >= 0 ? Palette.money : Palette.loss) }
                if let all = p.allAtHorizon, let h = p.horizon {
                    pill(Fmt.money(all, model), String(format: String(localized: "by %@ if every trial pays"), Fmt.date(h, "d MMM")), Palette.brand, dashed: true)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.money(p.real, model, compact: false)).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("real MRR, failed payments and trials left out").font(.callout).foregroundStyle(.secondary)
                }
                legend
                Chart {
                    ForEach(p.days.filter { $0.real != nil }) { d in
                        AreaMark(x: .value("Day", d.date), y: .value("MRR", Double(d.real!)))
                            .foregroundStyle(LinearGradient(colors: [Palette.brand.opacity(0.18), Palette.brand.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Day", d.date), y: .value("MRR", Double(d.real!)), series: .value("Line", "real"))
                            .foregroundStyle(Palette.brand).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(p.days.filter { $0.all != nil }) { d in
                        LineMark(x: .value("Day", d.date), y: .value("MRR", Double(d.all!)), series: .value("Line", "all"))
                            .foregroundStyle(Palette.brand).lineStyle(StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
                            .interpolationMethod(.stepEnd)
                    }
                    ForEach(p.days.filter { $0.atRate != nil }) { d in
                        LineMark(x: .value("Day", d.date), y: .value("MRR", Double(d.atRate!)), series: .value("Line", "rate"))
                            .foregroundStyle(Palette.mint).lineStyle(StrokeStyle(lineWidth: 1.6, dash: [2, 3]))
                            .interpolationMethod(.stepEnd)
                    }
                    if p.hasFuture {
                        RuleMark(x: .value("Today", today))
                            .foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .center) { Text("Today").font(.caption2).foregroundStyle(.secondary) }
                    }
                    // Last, so the label sits above every line
                    if let d = picked {
                        let mid = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
                        RuleMark(x: .value("Hover", d.date))
                            .foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: d.date > mid ? .leading : .trailing, alignment: .top, spacing: 8) { tip(d) }
                        if let v = d.real { PointMark(x: .value("Day", d.date), y: .value("MRR", Double(v))).foregroundStyle(Palette.brand).symbolSize(40) }
                        if d.real == nil, let v = d.all { PointMark(x: .value("Day", d.date), y: .value("MRR", Double(v))).foregroundStyle(Palette.brand).symbolSize(30) }
                        if d.real == nil, let v = d.atRate { PointMark(x: .value("Day", d.date), y: .value("MRR", Double(v))).foregroundStyle(Palette.mint).symbolSize(30) }
                    }
                }
                .chartXScale(domain: first...last)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                        AxisValueLabel { if let x = v.as(Double.self) { Text(Fmt.axis(Int(x), model)) } }
                    }
                }
                .chartXAxis(.hidden)
                .modifier(HoverDate(hover: $hover))
                .frame(height: 210)
                .padding(.top, 12)
                // The days' sign-ups under the curve, on the same days
                Chart {
                    ForEach(p.days.filter { $0.real != nil }) { d in
                        if d.newPaying > 0 { BarMark(x: .value("Day", d.date, unit: .day), y: .value("Count", d.newPaying)).foregroundStyle(Palette.money) }
                        if d.newTrials > 0 { BarMark(x: .value("Day", d.date, unit: .day), y: .value("Count", d.newTrials)).foregroundStyle(Color(red: 0.62, green: 0.68, blue: 0.82)) }
                        if d.cancelledTrials > 0 { BarMark(x: .value("Day", d.date, unit: .day), y: .value("Count", -d.cancelledTrials)).foregroundStyle(Palette.loss) }
                    }
                    if let d = picked {
                        RuleMark(x: .value("Hover", d.date.addingTimeInterval(43200))).foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .modifier(HoverDate(hover: $hover))
                .chartXScale(domain: first...last)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                        AxisValueLabel { if let x = v.as(Int.self) { Text("\(abs(x))") } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 80)
                .padding(.top, 10)
                barsLegend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Palette.brand, dash: nil, String(localized: "Real MRR"))
            if p.hasFuture {
                swatch(Palette.brand, dash: [6, 4], String(localized: "If every trial pays"))
                swatch(Palette.mint, dash: [2, 3], String(localized: "At the real conversion rate"))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var barsLegend: some View {
        let new = p.days.reduce(0) { $0 + $1.newTrials }, paying = p.days.reduce(0) { $0 + $1.newPaying }, cancelled = p.days.reduce(0) { $0 + $1.cancelledTrials }
        return HStack(spacing: 14) {
            dot(Palette.money, String(format: String(localized: "New paying customers (%lld)"), paying))
            dot(Color(red: 0.62, green: 0.68, blue: 0.82), String(format: String(localized: "New trials (%lld)"), new))
            dot(Palette.loss, String(format: String(localized: "Trials cancelled (%lld)"), cancelled))
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ c: Color, dash: [CGFloat]?, _ label: String) -> some View {
        HStack(spacing: 5) {
            Path { $0.move(to: CGPoint(x: 0, y: 4)); $0.addLine(to: CGPoint(x: 18, y: 4)) }
                .stroke(c, style: StrokeStyle(lineWidth: 2, dash: dash ?? []))
                .frame(width: 18, height: 8)
            Text(label)
        }
    }

    private func dot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label)
        }
    }

    private func pill(_ value: String, _ label: String, _ tint: Color, dashed: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(dashed ? 0.45 : 0.15), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
    }
}


// MARK: Hover labels

/// Follows the mouse over a chart and reports the date under it.
struct HoverDate: ViewModifier {
    @Binding var hover: Date?
    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc): hover = proxy.value(atX: loc.x - geo[proxy.plotAreaFrame].origin.x, as: Date.self)
                        case .ended: hover = nil
                        }
                    }
            }
        }
    }
}

/// The small card that shows the figures of the point under the mouse.
struct ChartTip: View {
    let title: String
    let rows: [(Color, String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(rows[i].0).frame(width: 8, height: 8)
                    Text(rows[i].1).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(rows[i].2).fontWeight(.semibold).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(minWidth: 170)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: Churn over time

/// The 30-day rolling churn of paying customers over the last 90 days, with the customers lost each day under it.
struct ChurnCard: View {
    @ObservedObject var model: Model
    @State private var hover: Date?

    var body: some View {
        let days = model.dashboard.churn
        let first = days.first?.date ?? Date(), last = (days.last?.date ?? Date()).addingTimeInterval(86400)
        let now = days.last?.rate
        let lost = days.reduce(0) { $0 + $1.lost }
        let picked = hover.flatMap { h in days.min { abs($0.date.addingTimeInterval(43200).timeIntervalSince(h)) < abs($1.date.addingTimeInterval(43200).timeIntervalSince(h)) } }
        let top = max(0.1, (days.compactMap(\.rate).max() ?? 0) * 1.25)
        Card(title: String(localized: "Churn over time"), subtitle: String(localized: "Paying customers, last 90 days")) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.percent(now)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((now ?? 0) > 0.1 ? Palette.loss : .primary)
                Text("30-day churn today").font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Path { $0.move(to: CGPoint(x: 0, y: 4)); $0.addLine(to: CGPoint(x: 18, y: 4)) }.stroke(Palette.loss, lineWidth: 2).frame(width: 18, height: 8)
                        Text("30-day churn")
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.loss.opacity(0.45)).frame(width: 9, height: 9)
                        Text(String(format: String(localized: "Customers lost that day (%lld)"), lost))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Chart {
                    ForEach(days.filter { $0.rate != nil }) { d in
                        AreaMark(x: .value("Day", d.date), y: .value("Churn", d.rate!))
                            .foregroundStyle(LinearGradient(colors: [Palette.loss.opacity(0.14), Palette.loss.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Day", d.date), y: .value("Churn", d.rate!))
                            .foregroundStyle(Palette.loss).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let d = picked {
                        let mid = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
                        RuleMark(x: .value("Hover", d.date))
                            .foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: d.date > mid ? .leading : .trailing, alignment: .top, spacing: 8) {
                                ChartTip(title: Fmt.date(d.date, "EEEE d MMM"), rows: [
                                    (Palette.loss, String(localized: "30-day churn"), Fmt.percent(d.rate)),
                                    (Palette.loss.opacity(0.45), String(localized: "Lost that day"), "\(d.lost)"),
                                    (Color.secondary, String(localized: "Paying 30 days earlier"), "\(d.base)"),
                                ])
                            }
                        if let r = d.rate { PointMark(x: .value("Day", d.date), y: .value("Churn", r)).foregroundStyle(Palette.loss).symbolSize(40) }
                    }
                }
                .chartXScale(domain: first...last)
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                        AxisValueLabel { if let x = v.as(Double.self) { Text(Fmt.percent(x, digits: 0)) } }
                    }
                }
                .chartXAxis(.hidden)
                .modifier(HoverDate(hover: $hover))
                .frame(height: 170)
                Chart {
                    ForEach(days.filter { $0.lost > 0 }) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("Lost", d.lost)).foregroundStyle(Palette.loss.opacity(0.45))
                    }
                    if let d = picked {
                        RuleMark(x: .value("Hover", d.date.addingTimeInterval(43200))).foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXScale(domain: first...last)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.line)
                        AxisValueLabel { if let x = v.as(Int.self) { Text("\(x)") } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 14)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) }
                }
                .modifier(HoverDate(hover: $hover))
                .frame(height: 70)
                .padding(.top, 8)
            }
        }
    }
}
