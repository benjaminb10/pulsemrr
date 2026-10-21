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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.accounts.isEmpty {
                empty.padding(16)
            } else {
                hero.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
                WeekChart(model: model).frame(height: 84).padding(.horizontal, 16).padding(.bottom, 14)
                Divider()
                ProjectsTable(model: model).padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ActivityList(model: model).padding(.horizontal, 16).padding(.vertical, 12)
            }
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 400)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Kaching").font(.headline)
            Text("Add a Stripe account to get a notification for every sale.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Add a Stripe account…") { openSettings() }
        }
    }

    private var hero: some View {
        let today = model.takings(0), yesterday = model.takings(1)
        let t = model.convert(today), y = model.convert(yesterday)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Amount(model: model, sums: today, font: .system(size: 30, weight: .bold, design: .rounded))
                }
                Spacer()
                Delta(today: t, yesterday: y)
            }
            HStack(spacing: 8) {
                Tile(title: String(localized: "Yesterday"), content: Amount(model: model, sums: yesterday, font: .system(size: 15, weight: .semibold, design: .rounded)))
                Tile(title: String(localized: "7 days"), content: Amount(model: model, sums: model.week(), font: .system(size: 15, weight: .semibold, design: .rounded)))
                Tile(title: "MRR", content: Amount(model: model, sums: model.mrrTotal, font: .system(size: 15, weight: .semibold, design: .rounded)))
            }
        }
    }

    @Environment(\.isSnapshot) private var isSnapshot

    @ViewBuilder private var footer: some View {
        if isSnapshot {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise"); Image(systemName: "bell.badge")
                (Text("Checked") + Text(" ") + Text("4 s")).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "gearshape"); Image(systemName: "power")
            }
            .foregroundStyle(.secondary)
        } else { liveFooter }
    }

    private var liveFooter: some View {
        HStack(spacing: 12) {
            Button { Task { await model.pollAll(); await model.refreshStats() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { model.replayRecent() } label: { Image(systemName: "bell.badge") }
                .help("Replay the latest notifications")
            if let t = model.lastPoll {
                (Text("Checked") + Text(" ") + Text(t, style: .relative)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if !model.notificationsAllowed {
                Image(systemName: "bell.slash").foregroundStyle(.orange)
                    .help("Notifications are off: System Settings › Notifications › Kaching")
            }
            Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Kaching")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.caption2.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            if model.recent.isEmpty {
                Text("Nothing in the last 7 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                let items = Array(model.recent.prefix(30))
                if isSnapshot {
                    VStack(spacing: 2) { ForEach(items.prefix(5)) { act in ActivityRow(model: model, act: act) } }
                } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { act in ActivityRow(model: model, act: act) }
                    }
                }
                .frame(height: min(CGFloat(items.count), 5) * 44)
                }
            }
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
        case .sale, .newSubscriber, .trialConverted, .payout: return Palette.money
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
                    let sign = [.sale, .payout, .newSubscriber, .trialConverted].contains(act.kind) ? "+" : (tone == Palette.loss ? "−" : "")
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
