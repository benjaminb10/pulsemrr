// The menu bar panel and the settings window.
import AppKit
import SwiftUI

enum Palette {
    static let money = Color(red: 0.11, green: 0.72, blue: 0.43)
    static let loss = Color(red: 0.90, green: 0.30, blue: 0.27)
}

struct MenuPanel: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.accounts.isEmpty {
                empty.padding(16)
            } else {
                header.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                if !model.todos.isEmpty {
                    TodoList(model: model).padding(.horizontal, 12).padding(.bottom, 10)
                }
                VStack(spacing: 8) {
                    ForEach(model.active) { a in ProjectCard(model: model, account: a) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
                Divider()
                ActivityList(model: model).padding(.horizontal, 12).padding(.vertical, 10)
            }
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 420)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Kaching").font(.headline)
            Text("Add a Stripe account to get a notification for every sale.").font(.callout).foregroundStyle(.secondary)
            Button("Add a Stripe account…") { openSettings() }
        }
    }

    /// The one line that answers "did I make money?": today, yesterday, and the MRR of every project added up.
    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Amount(model: model, sums: model.takings(0), font: .system(size: 28, weight: .bold, design: .rounded))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("New customers").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(model.newCustomers(0))").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(String(format: String(localized: "yesterday %lld"), model.newCustomers(1))).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .help(String(localized: "People who became Stripe customers today, trials included."))
            .padding(.trailing, 16)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Yesterday").font(.caption).foregroundStyle(.secondary)
                Amount(model: model, sums: model.takings(1), font: .system(size: 15, weight: .semibold, design: .rounded))
            }
            .padding(.trailing, 16)
            VStack(alignment: .trailing, spacing: 1) {
                Text("MRR").font(.caption).foregroundStyle(.secondary)
                Amount(model: model, sums: model.mrrTotal, font: .system(size: 15, weight: .semibold, design: .rounded))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if isSnapshot {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise"); Image(systemName: "bell.badge")
                (Text("Checked") + Text(" ") + Text("4 s")).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "gearshape"); Image(systemName: "power")
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 12) {
                Button { Task { await model.pollAll(); await model.refreshStats() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { model.replayRecent() } label: { Image(systemName: "bell.badge") }.help("Replay the latest notifications")
                if let t = model.lastPoll { (Text("Checked") + Text(" ") + Text(t, style: .relative)).font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                if !model.notificationsAllowed {
                    Image(systemName: "bell.slash").foregroundStyle(.orange).help("Notifications are off: System Settings › Notifications › Kaching")
                }
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Kaching")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Only shows when something needs chasing: each failed payment and each dispute, with who and how much.
struct TodoList: View {
    @ObservedObject var model: Model
    var body: some View {
        let items = model.todos
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.loss)
                Text("To do").fontWeight(.semibold)
                Text("· \(items.count)").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 4)
            ForEach(items.prefix(3)) { t in
                Button { NSWorkspace.shared.open(t.url) } label: {
                    HStack(spacing: 8) {
                        AccountIcon(model: model, account: t.account, size: 18)
                        Text(t.title).fontWeight(.medium)
                        if let who = t.who { Text(who).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer(minLength: 6)
                        Text(Money.format(t.amount, t.currency, compact: true)).monospacedDigit().foregroundStyle(Palette.loss)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Stripe")
            }
            if items.count > 3 {
                Text(String(format: String(localized: "and %lld more"), items.count - 3)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
        }
        .padding(6)
        .background(Palette.loss.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One project on one line: logo and name, 30 days of sales as a sparkline, MRR. Its own signals
/// (failed payments, trials with their conversion, churn) show underneath only when it has some.
struct ProjectCard: View {
    @ObservedObject var model: Model
    let account: Account

    var body: some View {
        let d = model.mrrDetail[account.id]
        let today = model.convert(model.takings(account, 0))
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                AccountIcon(model: model, account: account, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.callout.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 3) {
                        let n = model.newCustomers(account, 0)
                        if today > 0 {
                            Text("Today").foregroundStyle(.secondary)
                            Text("+" + Money.format(today, model.currency, compact: true)).fontWeight(.semibold).foregroundStyle(Palette.money)
                        } else if n == 0 {
                            Text("No sale today").foregroundStyle(.tertiary)
                        }
                        if n > 0 {
                            if today > 0 { Text("·").foregroundStyle(.tertiary) }
                            HStack(spacing: 2) {
                                Image(systemName: "person.fill").font(.system(size: 9))
                                Text("\(n)").fontWeight(.semibold)
                            }
                            .foregroundStyle(.secondary)
                            .help(String(format: String(localized: n > 1 ? "%lld new customers" : "%lld new customer"), n))
                        }
                    }
                    .font(.caption).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 6)
                Sparkline(values: model.month(account)).frame(width: 84, height: 24)
                VStack(alignment: .trailing, spacing: 0) {
                    Amount(model: model, sums: model.mrr[account.id] ?? [:], font: .system(size: 15, weight: .bold, design: .rounded), compact: true, approxMark: false)
                    Text(subscribers(d)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 70, alignment: .trailing)
            }
            if let d {
                let chips = signals(d)
                if !chips.isEmpty {
                    HStack(spacing: 6) { ForEach(chips, id: \.0) { chip($0.1, $0.2, $0.3) }; Spacer(minLength: 0) }
                        .padding(.leading, 38)
                }
            }
            if let err = model.errors[account.id] {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(1).padding(.leading, 38)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func subscribers(_ d: MrrSnapshot?) -> String {
        guard let n = d?.activeCount, n > 0 else { return String(localized: "MRR") }
        return String(format: String(localized: n > 1 ? "%lld subscribers" : "%lld subscriber"), n)
    }

    /// (key, icon, tint, text): only the signals this project actually has.
    private func signals(_ d: MrrSnapshot) -> [(String, String, Color, String)] {
        var out: [(String, String, Color, String)] = []
        if d.atRiskCount > 0 {
            out.append(("risk", "exclamationmark.triangle.fill", Palette.loss,
                        String(format: String(localized: d.atRiskCount > 1 ? "%lld failed payments" : "%lld failed payment"), d.atRiskCount) + " · " + Money.format(model.convert(d.atRisk), model.currency, compact: true)))
        }
        if d.trialCount > 0 {
            var text = String(format: String(localized: d.trialCount > 1 ? "%lld trials" : "%lld trial"), d.trialCount)
            if let c = d.conversion { text += " · \(Int((c * 100).rounded())) %" }
            out.append(("trials", "hourglass", .secondary, text))
        }
        if d.leavingCount > 0 {
            out.append(("leaving", "arrow.down.right", .secondary,
                        String(format: String(localized: d.leavingCount > 1 ? "%lld cancellations" : "%lld cancellation"), d.leavingCount)))
        }
        return out
    }

    private func chip(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background((tint == .secondary ? Color.primary : tint).opacity(0.07), in: Capsule())
        .lineLimit(1)
        .help(icon == "hourglass" ? String(localized: "Trials running now, and the share of this project's past trials that became paying.") : "")
    }
}

/// 30 days of sales as a soft area with a line; today is the last point.
struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            let top = CGFloat(max(values.max() ?? 0, 1)), w = geo.size.width, h = geo.size.height
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w
            let pts = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: h - 2 - CGFloat($0.element) / top * (h - 4)) }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Palette.money.opacity(0.22), Palette.money.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first); pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Palette.money, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = pts.last { Circle().fill(Palette.money).frame(width: 5, height: 5).position(last) }
            }
        }
        .help(String(localized: "Sales, last 30 days"))
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

struct ProjectsTable: View {
    @ObservedObject var model: Model
    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 9) {
            GridRow {
                Text("Project").gridColumnAlignment(.leading)
                Text("Today")
                Text("Yesterday")
                Text("MRR")
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(model.active) { a in
                GridRow {
                    HStack(spacing: 8) {
                        AccountIcon(model: model, account: a, size: 20)
                        Text(a.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.errors[a.id] != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(model.errors[a.id] ?? "")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                    Amount(model: model, sums: model.takings(a, 0), font: .callout.weight(.semibold), compact: true, dimZero: true, approxMark: false)
                    Amount(model: model, sums: model.takings(a, 1), font: .callout, compact: true, dimZero: true, approxMark: false)
                    Amount(model: model, sums: model.mrr[a.id] ?? [:], font: .callout, compact: true, dimZero: true, approxMark: false)
                }
                .font(.callout)
            }
        }
    }
}

struct ActivityList: View {
    @ObservedObject var model: Model
    @Environment(\.isSnapshot) private var isSnapshot

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Today") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        let f = DateFormatter(); f.locale = Money.locale; f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f.string(from: d).capitalized
    }

    var body: some View {
        let items = Array(model.feed.prefix(isSnapshot ? 5 : 40))
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.created) }.sorted { $0.key > $1.key }
        let content = VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.key) { day, acts in
                Text(dayTitle(day)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
                ForEach(acts) { act in ActivityRow(model: model, act: act) }
            }
        }
        if items.isEmpty {
            Text("Nothing in the last 7 days.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6)
        } else if isSnapshot {
            content
        } else {
            ScrollView { content }.frame(height: min(CGFloat(items.count) * 42 + CGFloat(groups.count) * 24, 260))
        }
    }
}

struct ActivityRow: View {
    @ObservedObject var model: Model
    let act: Activity
    @State private var hover = false
    @Environment(\.isSnapshot) private var isSnapshot

    private var tone: Color {
        switch act.kind {
        case .sale, .newSubscriber, .trialConverted: return Palette.money
        case .refund, .paymentFailed, .dispute, .ended, .canceled: return Palette.loss
        default: return .secondary
        }
    }

    var body: some View {
        let account = model.accounts.first { $0.id == act.accountID }
        if isSnapshot { row(account) } else {
        Button { NSWorkspace.shared.open(act.dashboardURL) } label: { row(account) }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open in Stripe")
        }
    }

    @ViewBuilder private func row(_ account: Account?) -> some View {
        Group {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    if let account { AccountIcon(model: model, account: account, size: 26) } else { Text("💳") }
                    Text(act.kind.emoji).font(.system(size: 10)).offset(x: 5, y: 4)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(act.kind.label).fontWeight(.medium)
                        Text("· \(account?.name ?? "")").foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    HStack(spacing: 4) {
                        if let who = act.who { Text(who).lineLimit(1).truncationMode(.middle) }
                        Text(act.created, format: .relative(presentation: .named))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let amount = act.amount, let cur = act.currency {
                    let sign = [.sale, .newSubscriber, .trialConverted].contains(act.kind) ? "+" : (tone == Palette.loss ? "−" : "")
                    Text(sign + Money.format(amount, cur, compact: true))
                        .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(tone)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
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
                    Text(account.live ? "LIVE" : "TEST").font(.caption2.bold())
                        .foregroundStyle(account.live ? .green : .orange)
                    Text(account.stripeID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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

/// Paste a key: Kaching finds the account's name and logo, you confirm.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Stripe account").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.callout.weight(.medium))
                SecureField("", text: $key, prompt: Text("rk_live_… or sk_live_…"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _ in found = nil; error = nil }
                Text("In Stripe: Developers › API keys › Create restricted key, with Read on Events, Charges, Customers, Subscriptions and Payouts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                TextField("", text: $connected, prompt: Text("acct_… (connected account, for a Connect platform)"))
                    .textFieldStyle(.roundedBorder).padding(.top, 4)
            }
            .font(.callout)

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
                Text("The key stays in this Mac's Keychain. Kaching only reads.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if found == nil {
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
                try await model.addAccount(name: name, emoji: "", key: key, connected: connected.trimmingCharacters(in: .whitespaces))
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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 660)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }
}
