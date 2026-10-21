// The dashboard's data and maths. Three things come from Stripe: every subscription's paying period (from the list
// the menu already reads every 5 minutes), a year of takings per day, and the last 90 days of failed invoices.
// Everything else (MRR over time, where it comes from, churn, lifetime value) is computed on the Mac from those.
import Foundation

/// One subscription, reduced to what the history needs: whose, how much a month, and when it was paying.
struct SubFact: Codable, Hashable {
    let id: String
    let customer: String
    let who: String?
    /// The customer's email: one person with two Stripe customers counts once.
    var email: String? = nil
    let currency: String
    /// Monthly equivalent of the list price, minor units (same rule as the menu's MRR).
    let monthly: Int
    /// When it started paying: the end of the trial, if there was one.
    let start: Date
    /// When it stopped paying: ended, or its renewal failed. Nil while it pays.
    let end: Date?
    let trialEnd: Date?
    let status: String
    /// When the subscription was created (a trial's start).
    var created: Date? = nil
    /// When it was cancelled (the click, not the end).
    var canceledAt: Date? = nil
    /// When a scheduled cancellation takes effect, if one is set.
    var cancelAt: Date? = nil

    func pays(at t: Date) -> Bool { start <= t && (end.map { t < $0 } ?? true) }
    /// Paid for at least a day: a trial cancelled before its end never did.
    var paidOnce: Bool { end.map { $0.timeIntervalSince(start) > 86400 } ?? (status != "trialing") }
}

/// A failed invoice of the last 90 days and how it ended up.
struct FailedInvoice: Codable, Identifiable, Hashable {
    enum State: String, Codable { case retrying, recovered, lost }
    let id: String
    let who: String?
    let amount: Int
    let currency: String
    let created: Date
    let state: State
    let live: Bool

    var url: URL { URL(string: (live ? "https://dashboard.stripe.com/" : "https://dashboard.stripe.com/test/") + "invoices/" + id)! }
}

/// A year of takings per day, kept on disk so the dashboard only asks Stripe for the last few days.
struct RevenueCache: Codable {
    var fetched: Date
    var days: [Date: [String: Int]]
}

extension StripeClient {
    /// One subscription as a SubFact. Nil for test customers, free plans and subscriptions that never started.
    static func fact(_ s: [String: Any]) -> SubFact? {
        let status = s["status"] as? String ?? ""
        guard !["incomplete", "incomplete_expired"].contains(status) else { return nil }
        let cus = s["customer"] as? [String: Any]
        guard cus?["deleted"] as? Bool != true else { return nil }
        guard let top = monthlyValue(s).max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        func date(_ v: Any?) -> Date? { (v as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        let items = (s["items"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        // Newer API versions moved the billing period onto the items
        let periodStart = date(s["current_period_start"]) ?? date(items.first?["current_period_start"])
        let periodEnd = date(s["current_period_end"]) ?? date(items.first?["current_period_end"])
        let trialEnd = date(s["trial_end"])
        let started = date(s["start_date"]) ?? date(s["created"]) ?? Date()
        let start = max(started, trialEnd ?? started)
        let end: Date?
        switch status {
        case "active", "trialing": end = nil
        case "past_due", "unpaid", "paused": end = periodStart ?? start
        default: end = date(s["ended_at"]) ?? date(s["canceled_at"]) ?? start
        }
        return SubFact(id: s["id"] as? String ?? "", customer: cus?["id"] as? String ?? (s["customer"] as? String ?? ""),
                       who: person(name: cus?["name"] as? String, email: cus?["email"] as? String),
                       email: (cus?["email"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
                       currency: top.key, monthly: top.value, start: start, end: end, trialEnd: trialEnd, status: status,
                       created: started, canceledAt: date(s["canceled_at"]),
                       cancelAt: date(s["cancel_at"]) ?? (s["cancel_at_period_end"] as? Bool == true ? periodEnd : nil))
    }

    /// Invoices of the last `days` days that failed at least once: still retrying, paid in the end, or given up.
    func failedInvoices(days: Int) async throws -> [FailedInvoice] {
        let from = Int(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
        let invoices = try await list("invoices", [("created[gte]", String(from))], max: 20000)
        var out: [FailedInvoice] = []
        for i in invoices {
            let attempts = i["attempt_count"] as? Int ?? 0
            let status = i["status"] as? String ?? ""
            let paid = i["amount_paid"] as? Int ?? 0
            let state: FailedInvoice.State
            switch status {
            case "paid" where attempts > 1: state = .recovered
            case "open" where attempts >= 1: state = i["next_payment_attempt"] is Int ? .retrying : .lost
            case "uncollectible": state = .lost
            case "void" where attempts >= 1 && paid == 0: state = .lost
            default: continue
            }
            out.append(FailedInvoice(id: i["id"] as? String ?? "",
                                     who: StripeClient.person(name: i["customer_name"] as? String, email: i["customer_email"] as? String),
                                     amount: state == .recovered ? paid : (i["amount_due"] as? Int ?? 0),
                                     currency: i["currency"] as? String ?? "eur",
                                     created: Date(timeIntervalSince1970: TimeInterval(i["created"] as? Int ?? 0)),
                                     state: state, live: i["livemode"] as? Bool ?? true))
        }
        return out.sorted { $0.created > $1.created }
    }
}

/// What moved the MRR between two dates, customer by customer, in the display currency.
struct Movement {
    var new = 0, expansion = 0, reactivation = 0, contraction = 0, churn = 0
    var newCustomers = 0, churnedCustomers = 0
    var startMrr = 0, endMrr = 0, startCustomers = 0, endCustomers = 0
    var net: Int { new + expansion + reactivation - contraction - churn }
}

/// Everything the dashboard window shows, computed once per refresh, in the display currency.
struct DashboardData {
    struct Point: Identifiable { let date: Date; let account: UUID; let value: Int; var id: String { account.uuidString + "\(date.timeIntervalSince1970)" } }
    struct Month: Identifiable { let month: Date; let move: Movement; var id: Date { month } }
    struct Person: Identifiable { let id: String; let account: UUID; let who: String; let mrr: Int; let date: Date }
    struct Project: Identifiable { let id: UUID; let mrr: Int; let growth: Double?; let customers: Int; let churn: Double?; let arpu: Int }
    struct Failed: Identifiable { let account: UUID; let invoice: FailedInvoice; let amount: Int; var id: String { invoice.id } }

    var series: [Point] = []
    var months: [Month] = []
    var last30 = Movement()
    var last90 = Movement()
    var trialsEnded = 0
    var trialConversion: Double?
    var revenue: [Date: [UUID: Int]] = [:]
    var failed: [Failed] = []
    var top: [Person] = []
    var churned: [Person] = []
    var projects: [Project] = []
    /// Average net new MRR a month over the last 3 full months.
    var pace: Int?

    var mrr: Int { last30.endMrr }
    var customers: Int { last30.endCustomers }
    var arpu: Int { customers > 0 ? mrr / customers : 0 }
    var growth: Double? { last30.startMrr > 0 ? Double(last30.endMrr - last30.startMrr) / Double(last30.startMrr) : nil }
    var customerChurn: Double? { last30.startCustomers > 0 ? Double(last30.churnedCustomers) / Double(last30.startCustomers) : nil }
    var revenueChurn: Double? { last30.startMrr > 0 ? Double(last30.churn + last30.contraction) / Double(last30.startMrr) : nil }
    /// ARPU divided by the monthly customer churn of the last 90 days.
    var ltv: Int? {
        guard last90.startCustomers > 0, last90.churnedCustomers > 0 else { return nil }
        let monthly = Double(last90.churnedCustomers) / Double(last90.startCustomers) / 3
        return Int(Double(arpu) / monthly)
    }
}

enum Analytics {
    private struct Item { let account: UUID; let key: String; let monthly: Int; let fact: SubFact }

    /// `accounts` is what the window looks at (one project or all); `all` feeds the per-project table.
    static func build(accounts: [Account], all: [Account], facts: [UUID: [SubFact]], revenue: [UUID: [Date: [String: Int]]],
                      failed: [UUID: [FailedInvoice]], months: Int, convert: (Int, String) -> Int, now: Date = Date()) -> DashboardData {
        func items(_ accs: [Account]) -> [Item] {
            accs.flatMap { a in (facts[a.id] ?? []).map { Item(account: a.id, key: a.id.uuidString + "|" + (($0.email?.isEmpty == false ? $0.email : nil) ?? $0.customer), monthly: convert($0.monthly, $0.currency), fact: $0) } }
        }
        let list = items(accounts)
        let cal = Calendar.current
        let day: TimeInterval = 86400
        var d = DashboardData()

        // The MRR curve: one point a week, per project
        let weeks = Int((Double(months) * 30.44 / 7).rounded())
        for w in stride(from: weeks, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(w) * 7 * day)
            var per: [UUID: Int] = [:]
            for it in list where it.fact.pays(at: t) { per[it.account, default: 0] += it.monthly }
            for a in accounts { d.series.append(.init(date: t, account: a.id, value: per[a.id] ?? 0)) }
        }

        // Where the MRR came from and went, calendar month by calendar month (this one so far)
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        for m in stride(from: months - 1, through: 0, by: -1) {
            let a = cal.date(byAdding: .month, value: -m, to: thisMonth)!
            let b = m == 0 ? now : cal.date(byAdding: .month, value: 1, to: a)!
            d.months.append(.init(month: a, move: movement(list, a, b)))
        }
        d.last30 = movement(list, now.addingTimeInterval(-30 * day), now)
        d.last90 = movement(list, now.addingTimeInterval(-90 * day), now)
        let full = d.months.dropLast().suffix(3)
        if !full.isEmpty { d.pace = full.reduce(0) { $0 + $1.move.net } / full.count }

        // Trials that ended in the last 90 days, and how many of them paid
        let ended = list.filter { it in it.fact.trialEnd.map { $0 > now.addingTimeInterval(-90 * day) && $0 <= now } ?? false }
        d.trialsEnded = ended.count
        if !ended.isEmpty { d.trialConversion = Double(ended.filter(\.fact.paidOnce).count) / Double(ended.count) }

        for a in accounts {
            for (date, sums) in revenue[a.id] ?? [:] {
                let v = sums.reduce(0) { $0 + convert($1.value, $1.key) }
                if v != 0 { d.revenue[date, default: [:]][a.id] = v }
            }
            let cur = (failed[a.id] ?? []).map { DashboardData.Failed(account: a.id, invoice: $0, amount: convert($0.amount, $0.currency)) }
            d.failed += cur
        }
        d.failed.sort { $0.invoice.created > $1.invoice.created }

        // Best customers now, and the ones who left in the last 90 days
        let byKey = Dictionary(grouping: list, by: \.key)
        let nowValues = values(list, now)
        for (key, value) in nowValues {
            guard let its = byKey[key], let first = its.first else { continue }
            let since = its.filter(\.fact.paidOnce).map(\.fact.start).min() ?? first.fact.start
            d.top.append(.init(id: key, account: first.account, who: its.compactMap(\.fact.who).first ?? first.fact.customer, mrr: value, date: since))
        }
        d.top.sort { $0.mrr > $1.mrr }
        d.top = Array(d.top.prefix(8))
        for (key, its) in byKey where nowValues[key] == nil {
            guard let last = its.compactMap({ $0.fact.paidOnce ? $0.fact.end : nil }).max(),
                  last > now.addingTimeInterval(-90 * day), let first = its.first else { continue }
            let lost = its.filter { $0.fact.pays(at: last.addingTimeInterval(-1)) }.reduce(0) { $0 + $1.monthly }
            guard lost > 0 else { continue }
            d.churned.append(.init(id: key, account: first.account, who: its.compactMap(\.fact.who).first ?? first.fact.customer, mrr: lost, date: last))
        }
        d.churned.sort { $0.date > $1.date }
        d.churned = Array(d.churned.prefix(8))

        for a in all {
            let m = movement(items([a]), now.addingTimeInterval(-30 * day), now)
            d.projects.append(.init(id: a.id, mrr: m.endMrr,
                                    growth: m.startMrr > 0 ? Double(m.endMrr - m.startMrr) / Double(m.startMrr) : nil,
                                    customers: m.endCustomers,
                                    churn: m.startCustomers > 0 ? Double(m.churnedCustomers) / Double(m.startCustomers) : nil,
                                    arpu: m.endCustomers > 0 ? m.endMrr / m.endCustomers : 0))
        }
        return d
    }

    /// Each customer's MRR at a date.
    private static func values(_ list: [Item], _ t: Date) -> [String: Int] {
        var v: [String: Int] = [:]
        for it in list where it.fact.pays(at: t) { v[it.key, default: 0] += it.monthly }
        return v
    }

    /// Customer by customer between two dates: new, back after leaving, paying more, paying less, gone.
    private static func movement(_ list: [Item], _ a: Date, _ b: Date) -> Movement {
        let va = values(list, a), vb = values(list, b)
        let paidBefore = Set(list.filter { $0.fact.start < a && $0.fact.paidOnce }.map(\.key))
        var m = Movement()
        m.startMrr = va.values.reduce(0, +); m.endMrr = vb.values.reduce(0, +)
        m.startCustomers = va.count; m.endCustomers = vb.count
        for key in Set(va.keys).union(vb.keys) {
            let x = va[key] ?? 0, y = vb[key] ?? 0
            if x == 0 {
                if paidBefore.contains(key) { m.reactivation += y } else { m.new += y; m.newCustomers += 1 }
            } else if y == 0 {
                m.churn += x; m.churnedCustomers += 1
            } else if y > x { m.expansion += y - x } else if x > y { m.contraction += x - y }
        }
        return m
    }
}

/// Trials and where they lead, the way the BeReach and Viewlify admin boards read them: the real MRR day by day,
/// the days' new trials, new payers and cancelled trials, then the coming days until the last running trial ends,
/// once if every trial pays and once at each project's real conversion rate. Paying subscriptions set to cancel
/// stop counting on their date.
struct Projection {
    struct Day: Identifiable {
        let date: Date
        var real: Int?
        var all: Int?
        var atRate: Int?
        var newTrials = 0
        var newPaying = 0
        var cancelledTrials = 0
        var id: Date { date }
    }

    var days: [Day] = []
    var real = 0
    var real7Ago: Int?
    var trials = 0
    var trialCount = 0
    var trialsCancelling = 0
    var atRisk = 0
    var atRiskCount = 0
    /// Real MRR + each project's running trials x its own conversion rate.
    var projected = 0
    var ended = 0, endedPaying = 0, endedFailed = 0, endedCancelled = 0
    var rate: Double? { ended > 0 ? Double(endedPaying) / Double(ended) : nil }
    /// The last running trial's end, and the MRR then if every trial pays.
    var horizon: Date?
    var allAtHorizon: Int?
    var hasFuture: Bool { days.contains { $0.all != nil } }

    static func build(accounts: [Account], facts: [UUID: [SubFact]], snapshots: [UUID: MrrSnapshot],
                      convert: (Int, String) -> Int, now: Date = Date(), back: Int = 30, maxAhead: Int = 60) -> Projection {
        let cal = Calendar.current
        let day: TimeInterval = 86400
        var p = Projection()
        let today = cal.startOfDay(for: now)
        func endOfDay(_ d: Date) -> Date { min(now, cal.date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-1)) }

        struct Item { let account: UUID; let monthly: Int; let fact: SubFact }
        let items = accounts.flatMap { a in (facts[a.id] ?? []).map { Item(account: a.id, monthly: convert($0.monthly, $0.currency), fact: $0) } }
        let rates = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, snapshots[$0.id]?.conversion ?? 0) })

        // The past, one point a day
        for k in stride(from: back, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -k, to: today)!
            let t = k == 0 ? now : endOfDay(d)
            var row = Day(date: d)
            row.real = items.filter { $0.fact.pays(at: t) }.reduce(0) { $0 + $1.monthly }
            for it in items {
                if it.fact.trialEnd != nil, let c = it.fact.created, cal.isDate(c, inSameDayAs: d) { row.newTrials += 1 }
                if it.fact.paidOnce, cal.isDate(it.fact.start, inSameDayAs: d), it.fact.start <= now { row.newPaying += 1 }
                if let te = it.fact.trialEnd, let c = it.fact.canceledAt, c <= te, cal.isDate(c, inSameDayAs: d) { row.cancelledTrials += 1 }
            }
            p.days.append(row)
        }
        p.real = p.days.last?.real ?? 0
        if p.days.count > 7 { p.real7Ago = p.days[p.days.count - 8].real }

        // Running trials that aren't set to cancel, and the ones that are
        let trialing = items.filter { $0.fact.status == "trialing" }
        let live = trialing.filter { $0.fact.cancelAt == nil }
        p.trials = live.reduce(0) { $0 + $1.monthly }
        p.trialCount = live.count
        p.trialsCancelling = trialing.count - live.count
        let paying = items.filter { $0.fact.pays(at: now) }
        p.projected = p.real + Int(live.reduce(0.0) { $0 + Double($1.monthly) * (rates[$1.account] ?? 0) }.rounded())

        for a in accounts {
            guard let s = snapshots[a.id] else { continue }
            p.atRisk += s.atRisk.reduce(0) { $0 + convert($1.value, $1.key) }
            p.atRiskCount += s.atRiskCount
            p.ended += s.trialsEnded; p.endedPaying += s.trialsPaying
            p.endedFailed += s.trialsFailed; p.endedCancelled += s.trialsCancelled
        }

        // The future, to the last running trial's end
        let ends = live.compactMap(\.fact.trialEnd).filter { $0 > now }
        if let last = ends.max() {
            let horizon = min(last, now.addingTimeInterval(Double(maxAhead) * day))
            p.horizon = horizon
            // Today's point opens the dashed lines, so they leave from the real curve
            if let i = p.days.indices.last { p.days[i].all = p.real; p.days[i].atRate = p.real }
            var d = cal.date(byAdding: .day, value: 1, to: today)!
            while d <= horizon {
                let t = cal.date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-1)
                let base = paying.filter { $0.fact.cancelAt.map { t < $0 } ?? true }.reduce(0) { $0 + $1.monthly }
                let joined = live.filter { ($0.fact.trialEnd ?? .distantFuture) <= t }
                let all = base + joined.reduce(0) { $0 + $1.monthly }
                let atRate = base + Int(joined.reduce(0.0) { $0 + Double($1.monthly) * (rates[$1.account] ?? 0) }.rounded())
                p.days.append(Day(date: d, all: all, atRate: atRate))
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            p.allAtHorizon = p.days.last?.all
        }
        return p
    }
}
