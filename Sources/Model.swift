// The app's brain: polls each Stripe account, turns new events into native notifications,
// and keeps today's takings and the MRR fresh for the menu bar.
import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class Model: ObservableObject {
    @Published var accounts: [Account] = Disk.read("accounts.json", as: [Account].self) ?? [] { didSet { if persist { Disk.write(accounts, "accounts.json") } } }
    @Published var prefs: Prefs = Disk.read("prefs.json", as: Prefs.self) ?? Prefs() { didSet { if persist { Disk.write(prefs, "prefs.json") }; if prefs.pollSeconds != oldValue.pollSeconds { schedule() }; if prefs.displayCurrency != oldValue.displayCurrency { ratesAt = nil; Task { await refreshRates() } } } }
    @Published var recent: [Activity] = Disk.read("recent.json", as: [Activity].self) ?? [] { didSet { if persist { Disk.write(recent, "recent.json") } } }
    @Published var daily: [UUID: [Date: [String: Int]]] = [:]
    /// Units of each currency for one unit of the display currency (ECB rates), e.g. ["usd": 1.08] for EUR.
    @Published var rates: [String: Double] = Disk.read("rates.json", as: [String: Double].self) ?? [:] { didSet { if persist { Disk.write(rates, "rates.json") } } }
    @Published var mrr: [UUID: [String: Int]] = [:]
    @Published var subscribers: [UUID: Int] = [:]
    @Published var mrrDetail: [UUID: MrrSnapshot] = [:]
    @Published var signups: [UUID: [Date: Int]] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var lastPoll: Date?
    @Published var notificationsAllowed = true
    @Published var logos: [UUID: NSImage] = [:]

    // The dashboard window
    @Published var facts: [UUID: [SubFact]] = [:]
    @Published var revenue: [UUID: [Date: [String: Int]]] = [:]
    @Published var failedInvoices: [UUID: [FailedInvoice]] = [:]
    /// Nil: all projects.
    @Published var dashboardScope: UUID? { didSet { rebuildDashboard() } }
    @Published var dashboardMonths = 12 { didSet { rebuildDashboard() } }
    @Published var dashboard = DashboardData()
    @Published var dashboardLoading = false
    @Published var dashboardUpdated: Date?
    var dashboardOpen = false
    private var revenueFetched: [UUID: Date] = [:]

    /// False for the demo: nothing is read from or written to disk, nothing is fetched.
    var persist = true
    private var cursors: [String: Cursor] = Disk.read("cursors.json", as: [String: Cursor].self) ?? [:]
    private var timer: Timer?
    private var statsTimer: Timer?
    private var recapTimer: Timer?
    private var polling = false
    private var customerNames: [String: String] = [:]

    // MARK: menu bar

    var currency: String { prefs.displayCurrency }

    /// An amount in minor units of any currency, converted to the display currency (minor units).
    func convert(_ amount: Int, _ cur: String) -> Int {
        let c = cur.lowercased()
        if c == currency { return amount }
        guard let rate = rates[c], rate > 0 else { return amount }
        return Int((Double(amount) / rate).rounded())
    }

    func convert(_ sums: [String: Int]) -> Int { sums.reduce(0) { $0 + convert($1.value, $1.key) } }

    /// True when a total mixes currencies, so the converted figure is an estimate.
    func isConverted(_ sums: [String: Int]) -> Bool { sums.keys.contains { $0 != currency && (sums[$0] ?? 0) != 0 } }

    func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
    }

    /// One account's takings on a day (0 = today, 1 = yesterday), in its original currencies.
    func takings(_ a: Account, _ offset: Int) -> [String: Int] { daily[a.id]?[day(offset)] ?? [:] }

    /// New customers on a day (0 = today, 1 = yesterday): one account, or all watched ones.
    func newCustomers(_ a: Account, _ offset: Int) -> Int { signups[a.id]?[day(offset)] ?? 0 }
    func newCustomers(_ offset: Int) -> Int { active.reduce(0) { $0 + newCustomers($1, offset) } }

    func takings(_ offset: Int) -> [String: Int] { sum(active.map { takings($0, offset) }) }

    /// The last 7 days, today included, in the original currencies: one account, or all of them.
    func week(_ a: Account? = nil) -> [String: Int] {
        sum((0..<7).map { offset in a.map { takings($0, offset) } ?? takings(offset) })
    }

    /// One account's last 30 days of takings, oldest first, converted: for its sparkline.
    func month(_ a: Account) -> [Int] { (0..<30).reversed().map { convert(takings(a, $0)) } }
    func monthTotal(_ a: Account) -> [String: Int] { sum((0..<30).map { takings(a, $0) }) }

    /// What needs a look, across accounts: failed payments, then disputes of the last 30 days.
    struct Todo: Identifiable { let id: String; let account: Account; let title: String; let who: String?; let amount: Int; let currency: String; let url: URL; let isDispute: Bool }
    var todos: [Todo] {
        var out: [Todo] = []
        for a in active {
            let base = a.live ? "https://dashboard.stripe.com/" : "https://dashboard.stripe.com/test/"
            for f in mrrDetail[a.id]?.failing ?? [] {
                out.append(Todo(id: f.id, account: a, title: String(localized: "Payment failed"), who: f.who, amount: f.amount, currency: f.currency,
                                url: URL(string: base + "subscriptions/" + f.id)!, isDispute: false))
            }
        }
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        for act in recent where act.kind == .dispute && act.created > monthAgo {
            guard let a = active.first(where: { $0.id == act.accountID }) else { continue }
            out.insert(Todo(id: act.id, account: a, title: String(localized: "Dispute"), who: act.who, amount: act.amount ?? 0, currency: act.currency ?? a.currency,
                            url: act.dashboardURL, isDispute: true), at: 0)
        }
        return out
    }

    /// The feed without noise: a "new customer" is dropped when the same customer started a trial,
    /// a subscription or paid within ten minutes of it.
    var feed: [Activity] {
        recent.filter { act in
            guard act.kind == .newCustomer, let cus = act.customerID else { return true }
            return !recent.contains { $0.id != act.id && $0.customerID == cus && abs($0.created.timeIntervalSince(act.created)) < 600 && $0.kind != .newCustomer }
        }
    }

    /// The last 7 days, oldest first, converted: for the chart.
    var lastWeek: [(day: Date, amount: Int)] { (0..<7).reversed().map { (day($0), convert(takings($0))) } }

    var mrrTotal: [String: Int] { sum(active.compactMap { mrr[$0.id] }) }
    var active: [Account] { accounts.filter(\.enabled) }

    // The MRR breakdown across all watched accounts, converted to the display currency.
    private var details: [MrrSnapshot] { active.compactMap { mrrDetail[$0.id] } }
    var atRiskTotal: (amount: Int, count: Int) { (convert(sum(details.map(\.atRisk))), details.reduce(0) { $0 + $1.atRiskCount }) }
    var leavingTotal: (amount: Int, count: Int) { (convert(sum(details.map(\.leaving))), details.reduce(0) { $0 + $1.leavingCount }) }
    var trialsTotal: (amount: Int, count: Int) { (convert(sum(details.map(\.trials))), details.reduce(0) { $0 + $1.trialCount }) }
    /// Conversion of ended trials over every account (each trial weighs the same).
    var conversionTotal: Double? {
        let ended = details.reduce(0) { $0 + $1.trialsEnded }
        return ended > 0 ? Double(details.reduce(0) { $0 + $1.trialsPaying }) / Double(ended) : nil
    }
    /// Real MRR plus each account's live trials weighted by that account's own conversion rate.
    var projectedTotal: Int? {
        guard details.contains(where: { $0.conversion != nil }) else { return nil }
        return details.reduce(0) { acc, d in acc + convert(d.real) + Int((Double(convert(d.trials)) * (d.conversion ?? 0)).rounded()) }
    }

    var menuBarTitle: String {
        guard prefs.showAmountInMenuBar, !accounts.isEmpty else { return "" }
        return Money.format(convert(takings(0)), currency, compact: true)
    }

    private func sum(_ maps: [[String: Int]]) -> [String: Int] {
        maps.reduce(into: [:]) { acc, m in for (k, v) in m { acc[k, default: 0] += v } }
    }

    // MARK: lifecycle

    func start() {
        // A menu bar app is only useful when it's running: open at login by default, once. Settings can turn it off.
        if !UserDefaults.standard.bool(forKey: "didSetLaunchAtLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetLaunchAtLogin")
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in self.notificationsAllowed = ok }
        }
        schedule()
        Task { await fillMissingLogos(); await pollAll(); await refreshStats() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(15, prefs.pollSeconds)), repeats: true) { _ in
            Task { @MainActor in await self.pollAll() }
        }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await self.refreshStats() }
        }
        // Once a minute: is it time for the daily recap? Also catches up after the Mac wakes from sleep.
        recapTimer?.invalidate()
        recapTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await self.recapIfDue() }
        }
    }

    func client(_ a: Account) -> StripeClient? {
        guard let key = Keychain.load(a.id) else { return nil }
        return StripeClient(key: key, connectedAccount: a.connectedAccount.isEmpty ? nil : a.connectedAccount)
    }

    // MARK: polling

    func pollAll() async {
        guard persist, !polling else { return }
        polling = true
        defer { polling = false }
        var anyMoney = false
        for a in accounts where a.enabled {
            if await poll(a) { anyMoney = true }
        }
        lastPoll = Date()
        if anyMoney { await refreshStats() }
    }

    /// Returns true when something that moves today's total or the MRR happened.
    private func poll(_ a: Account) async -> Bool {
        guard let c = client(a) else { errors[a.id] = String(localized: "Key not found in the Keychain"); return false }
        let key = a.id.uuidString
        // First time for this account: start from now, so years of history don't turn into notifications.
        guard var cursor = cursors[key] else {
            cursors[key] = Cursor(since: Int(Date().timeIntervalSince1970))
            saveCursors()
            await loadHistory(a, c)
            return false
        }
        do {
            let raw = try await c.events(since: cursor.since - 1)
            errors[a.id] = nil
            let fresh = raw.filter { e in
                guard let id = e["id"] as? String else { return false }
                return !cursor.seen.contains(id) && (e["created"] as? Int ?? 0) >= cursor.since
            }.sorted { ($0["created"] as? Int ?? 0) < ($1["created"] as? Int ?? 0) }
            guard !fresh.isEmpty else { return false }
            if let newest = fresh.compactMap({ $0["created"] as? Int }).max() {
                if newest > cursor.since { cursor = Cursor(since: newest, seen: []) }
                cursor.seen += fresh.filter { ($0["created"] as? Int) == cursor.since }.compactMap { $0["id"] as? String }
            }
            cursors[key] = cursor
            saveCursors()
            var moneyMoved = false
            var acts: [Activity] = []
            for e in fresh {
                guard var act = Activity.from(e, account: a.id) else { continue }
                if act.who == nil, let cus = act.customerID { act.who = await name(of: cus, c) }
                remember(act)
                acts.append(act)
                moneyMoved = true
            }
            for act in acts where prefs.kinds.contains(act.kind) {
                // A sign-up usually comes as "new customer" plus "trial started" or a sale: notify the more telling one only
                if act.kind == .newCustomer, let cus = act.customerID,
                   acts.contains(where: { $0.customerID == cus && $0.kind != .newCustomer && prefs.kinds.contains($0.kind) }) { continue }
                notify(act, a)
            }
            return moneyMoved
        } catch {
            errors[a.id] = error.localizedDescription
            return false
        }
    }

    /// The last week's events, shown in the menu without notifying.
    private func loadHistory(_ a: Account, _ c: StripeClient) async {
        guard let raw = try? await c.events(since: Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)) else { return }
        for e in raw.prefix(30).reversed() {
            guard var act = Activity.from(e, account: a.id) else { continue }
            if act.who == nil, let cus = act.customerID { act.who = await name(of: cus, c) }
            remember(act)
        }
    }

    private func name(of customer: String, _ c: StripeClient) async -> String? {
        if let n = customerNames[customer] { return n }
        let n = await c.customerLabel(customer)
        if let n { customerNames[customer] = n }
        return n
    }

    private func remember(_ act: Activity) {
        guard !recent.contains(where: { $0.id == act.id }) else { return }
        recent.append(act)
        recent.sort { $0.created > $1.created }
        if recent.count > 400 { recent = Array(recent.prefix(400)) }
    }

    private func saveCursors() { if persist { Disk.write(cursors, "cursors.json") } }

    // MARK: stats

    func refreshStats() async {
        guard persist else { return }
        await refreshRates()
        for a in accounts where a.enabled {
            guard let c = client(a) else { continue }
            do {
                daily[a.id] = try await c.daily(days: 30)
                signups[a.id] = try await c.newCustomers(days: 2)
                let (m, f) = try await c.mrrAndHistory()
                facts[a.id] = f
                if persist { Disk.write(f, "history/subscriptions-\(a.id.uuidString).json") }
                mrr[a.id] = m.real
                mrrDetail[a.id] = m
                subscribers[a.id] = m.activeCount
                errors[a.id] = nil
            } catch {
                errors[a.id] = error.localizedDescription
            }
        }
        if dashboardOpen { rebuildDashboard() }
    }

    // MARK: dashboard

    /// Shows what's on disk at once, then asks Stripe for what's missing or stale: the subscriptions when never read,
    /// a year of takings the first time (then the last days only), and the failed invoices of the last 90 days.
    func loadDashboard(force: Bool = false) async {
        guard persist else { rebuildDashboard(); return }
        guard !dashboardLoading else { return }
        dashboardLoading = true
        defer { dashboardLoading = false }
        for a in active {
            let id = a.id.uuidString
            if facts[a.id] == nil { facts[a.id] = Disk.read("history/subscriptions-\(id).json", as: [SubFact].self) }
            if revenue[a.id] == nil, let r = Disk.read("history/revenue-\(id).json", as: RevenueCache.self) {
                revenue[a.id] = r.days; revenueFetched[a.id] = r.fetched
            }
            if failedInvoices[a.id] == nil { failedInvoices[a.id] = Disk.read("history/failed-\(id).json", as: [FailedInvoice].self) }
        }
        rebuildDashboard()
        await refreshRates()
        for a in active {
            guard let c = client(a) else { continue }
            let id = a.id.uuidString
            do {
                if force || facts[a.id] == nil {
                    let (m, f) = try await c.mrrAndHistory()
                    facts[a.id] = f; mrr[a.id] = m.real; mrrDetail[a.id] = m; subscribers[a.id] = m.activeCount
                    Disk.write(f, "history/subscriptions-\(id).json")
                }
                let fetched = revenueFetched[a.id]
                if force || fetched == nil || Date().timeIntervalSince(fetched!) > 600 {
                    // A full year once, then only the days since the last read (and a few before, for late refunds)
                    let cached = fetched == nil ? nil : revenue[a.id]
                    let days = cached == nil ? 366 : min(366, Int(Date().timeIntervalSince(fetched!) / 86400) + 8)
                    let fresh = try await c.daily(days: days, max: 200_000)
                    let cut = day(days - 1)
                    var merged = (cached ?? [:]).filter { $0.key < cut && $0.key >= day(400) }
                    for (k, v) in fresh { merged[k] = v }
                    revenue[a.id] = merged
                    revenueFetched[a.id] = Date()
                    Disk.write(RevenueCache(fetched: Date(), days: merged), "history/revenue-\(id).json")
                    // A restricted key without Invoices read access still gets the rest of the dashboard
                    let failed = (try? await c.failedInvoices(days: 90)) ?? []
                    failedInvoices[a.id] = failed
                    Disk.write(failed, "history/failed-\(id).json")
                }
                errors[a.id] = nil
            } catch {
                errors[a.id] = error.localizedDescription
            }
            rebuildDashboard()
        }
        dashboardUpdated = Date()
    }

    func rebuildDashboard() {
        let scope = dashboardScope.flatMap { id in active.first { $0.id == id } }
        dashboard = Analytics.build(accounts: scope.map { [$0] } ?? active, all: active, facts: facts, revenue: revenue,
                                    failed: failedInvoices, months: dashboardMonths, convert: convert)
    }

    /// ECB reference rates (frankfurter.app, free, no key), refreshed every 6 hours.
    func refreshRates() async {
        if let at = ratesAt, Date().timeIntervalSince(at) < 6 * 3600, !rates.isEmpty { return }
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(currency.uppercased())"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = json["rates"] as? [String: Double] else { return }
        rates = Dictionary(uniqueKeysWithValues: r.map { ($0.key.lowercased(), $0.value) })
        ratesAt = Date()
    }
    private var ratesAt: Date?

    // MARK: daily recap

    private var lastRecapDay: String {
        get { UserDefaults.standard.string(forKey: "lastRecapDay") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastRecapDay") }
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    func recapIfDue() async {
        guard prefs.recapEnabled, !accounts.isEmpty else { return }
        let now = Date()
        guard Calendar.current.component(.hour, from: now) >= prefs.recapHour, lastRecapDay != dayKey(now) else { return }
        await refreshStats()
        sendRecap()
        lastRecapDay = dayKey(now)
    }

    /// What today looked like, in one notification.
    func recapText() -> (title: String, body: String) {
        let start = Calendar.current.startOfDay(for: Date())
        let ids = Set(active.map(\.id))
        let todays = recent.filter { $0.created >= start && ids.contains($0.accountID) }
        func count(_ kinds: [EventKind]) -> Int { todays.filter { kinds.contains($0.kind) }.count }
        let t = convert(takings(0)), y = convert(takings(1))
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("EEEE")
        var title = "📊 " + String(format: String(localized: "%@ recap: %@"), f.string(from: Date()), (isConverted(takings(0)) ? "≈ " : "") + Money.format(t, currency))
        if y > 0 {
            let pct = Int((Double(t - y) / Double(y) * 100).rounded())
            title += " (\(pct >= 0 ? "+" : "")\(pct) % " + String(localized: "vs yesterday") + ")"
        }
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) " + (n > 1 ? many : one)) } }
        add(newCustomers(0), String(localized: "new customer"), String(localized: "new customers"))
        add(count([.sale]), String(localized: "sale"), String(localized: "sales"))
        add(count([.newSubscriber]), String(localized: "new subscriber"), String(localized: "new subscribers"))
        add(count([.trialStarted]), String(localized: "trial started"), String(localized: "trials started"))
        add(count([.trialConverted]), String(localized: "trial converted"), String(localized: "trials converted"))
        add(count([.canceled, .ended]), String(localized: "cancellation"), String(localized: "cancellations"))
        add(count([.paymentFailed]), String(localized: "failed payment"), String(localized: "failed payments"))
        add(count([.refund]), String(localized: "refund"), String(localized: "refunds"))
        add(count([.dispute]), String(localized: "dispute"), String(localized: "disputes"))
        if let best = active.map({ ($0, convert(takings($0, 0))) }).filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }), active.count > 1 {
            parts.append(String(localized: "Top:") + " \(best.0.name) \(Money.format(best.1, currency, compact: true))")
        }
        parts.append("MRR \(Money.format(convert(mrrTotal), currency, compact: true))")
        return (title, parts.isEmpty ? String(localized: "Quiet day.") : parts.joined(separator: " · "))
    }

    func sendRecap() {
        let (title, body) = recapText()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "recap"
        if prefs.sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recap-" + dayKey(Date()) + "-" + UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: notifications

    func title(_ act: Activity, _ a: Account?) -> String {
        "\(act.kind.emoji) \(a?.name ?? "Stripe") · \(act.kind.label)"
    }

    func detail(_ act: Activity) -> String {
        var parts: [String] = []
        if let amount = act.amount, let cur = act.currency {
            let sign = act.kind == .sale || act.kind == .payout ? "+" : ""
            parts.append(sign + Money.format(amount, cur))
        }
        if let who = act.who { parts.append(who) }
        if !act.live { parts.append(String(localized: "test mode")) }
        return parts.isEmpty ? act.kind.label : parts.joined(separator: " · ")
    }

    func notify(_ act: Activity, _ a: Account) {
        let content = UNMutableNotificationContent()
        content.title = title(act, a)
        content.body = detail(act)
        content.threadIdentifier = a.id.uuidString
        content.userInfo = ["url": act.dashboardURL.absoluteString]
        if prefs.sound {
            // Money coming in gets the cash register; everything else the system sound.
            let cashIn: Set<EventKind> = [.sale, .newSubscriber, .trialConverted, .payout]
            content.sound = cashIn.contains(act.kind) ? UNNotificationSound(named: UNNotificationSoundName("cash.caf")) : .default
        }
        if a.useLogo, FileManager.default.fileExists(atPath: a.logoURL.path) {
            // A notification attachment is moved into the system's store, so hand it a copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            if (try? FileManager.default.copyItem(at: a.logoURL, to: copy)) != nil,
               let att = try? UNNotificationAttachment(identifier: "logo", url: copy) { content.attachments = [att] }
        }
        let req = UNNotificationRequest(identifier: act.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Plays the last few real events again as notifications, to check how they look.
    func replayRecent() {
        let sample = recent.prefix(3)
        if sample.isEmpty {
            let content = UNMutableNotificationContent()
            content.title = "💰 PulseMRR · " + String(localized: "Test")
            content.body = String(localized: "Notifications work. Your next sales will show up here.")
            if prefs.sound { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for (i, act) in sample.reversed().enumerated() {
            guard let a = accounts.first(where: { $0.id == act.accountID }) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) {
                let copy = Activity(id: UUID().uuidString, kind: act.kind, accountID: act.accountID, created: act.created,
                                    amount: act.amount, currency: act.currency, who: act.who, customerID: act.customerID,
                                    objectID: act.objectID, live: act.live)
                self.notify(copy, a)
            }
        }
    }

    // MARK: accounts

    /// Checks a key with Stripe without saving anything: who it belongs to, and their logo.
    func inspect(key: String, connected: String) async throws -> (StripeClient.AccountInfo, NSImage?) {
        let c = StripeClient(key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                             connectedAccount: connected.isEmpty ? nil : connected)
        let info = try await c.account()
        return (info, await logo(info, c))
    }

    /// The Stripe branding icon, or else the website's favicon.
    private func logo(_ info: StripeClient.AccountInfo, _ c: StripeClient) async -> NSImage? {
        if let file = info.iconFile, let data = await c.fileContents(file), let img = NSImage(data: data) { return img }
        guard let site = info.website, let host = URL(string: site.contains("://") ? site : "https://" + site)?.host,
              let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data), img.size.width >= 32 else { return nil }
        return img
    }

    /// Checks the key with Stripe, then saves the account (key in the Keychain, logo in Application Support).
    @discardableResult
    func addAccount(name: String, emoji: String, key: String, connected: String) async throws -> Account {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let (info, img) = try await inspect(key: cleanKey, connected: connected)
        var a = Account(name: name.isEmpty ? info.name : name, emoji: emoji.isEmpty ? "💳" : emoji,
                        connectedAccount: connected, stripeID: info.id, currency: info.currency, live: info.live)
        a.website = info.website ?? ""
        if let existing = accounts.firstIndex(where: { $0.stripeID == info.id && $0.connectedAccount == connected }) {
            a.id = accounts[existing].id
            a.useLogo = accounts[existing].useLogo
            accounts[existing] = a
        } else {
            accounts.append(a)
        }
        Keychain.save(cleanKey, for: a.id)
        saveLogo(img, for: a)
        Task { await pollAll(); await refreshStats() }
        return a
    }

    func saveLogo(_ img: NSImage?, for a: Account) {
        try? FileManager.default.createDirectory(at: a.logoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let img, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: a.logoURL)
        logos[a.id] = img
    }

    /// Fetches the logo of accounts added before logos existed.
    func fillMissingLogos() async {
        for a in accounts where logos[a.id] == nil {
            if let img = NSImage(contentsOf: a.logoURL) { logos[a.id] = img; continue }
            guard let c = client(a), let info = try? await c.account() else { continue }
            if let i = accounts.firstIndex(where: { $0.id == a.id }), accounts[i].website.isEmpty { accounts[i].website = info.website ?? "" }
            saveLogo(await logo(info, c), for: a)
        }
    }

    func move(from: IndexSet, to: Int) { accounts.move(fromOffsets: from, toOffset: to) }

    func remove(_ a: Account) {
        Keychain.delete(a.id)
        accounts.removeAll { $0.id == a.id }
        cursors[a.id.uuidString] = nil
        saveCursors()
        recent.removeAll { $0.accountID == a.id }
        try? FileManager.default.removeItem(at: a.logoURL)
        logos[a.id] = nil
        daily[a.id] = nil
        signups[a.id] = nil
        mrr[a.id] = nil
        mrrDetail[a.id] = nil
        facts[a.id] = nil; revenue[a.id] = nil; failedInvoices[a.id] = nil
        for f in ["subscriptions", "revenue", "failed"] {
            try? FileManager.default.removeItem(at: Disk.folder.appendingPathComponent("history/\(f)-\(a.id.uuidString).json"))
        }
        if dashboardScope == a.id { dashboardScope = nil }
    }

    /// What macOS allows for PulseMRR's notifications, for the settings and for --notif-status.
    func notificationStatus() async -> String {
        let st = await UNUserNotificationCenter.current().notificationSettings()
        let auth: String
        switch st.authorizationStatus {
        case .authorized: auth = "authorized"
        case .denied: auth = "denied"
        case .notDetermined: auth = "notDetermined"
        case .provisional: auth = "provisional"
        default: auth = "other"
        }
        let style: String
        switch st.alertStyle {
        case .alert: style = "alert (persistent)"
        case .banner: style = "banner (temporary)"
        default: style = "none"
        }
        return "authorization=\(auth) style=\(style) sound=\(st.soundSetting == .enabled) center=\(st.notificationCenterSetting == .enabled)"
    }

    /// Opens PulseMRR's page in System Settings › Notifications.
    func openNotificationSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.pulsemrr",
                    "x-apple.systempreferences:com.apple.preference.notifications?id=app.pulsemrr"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }
}
