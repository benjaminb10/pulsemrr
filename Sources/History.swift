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
    /// When the trial started (Stripe's trial_start).
    var trialStart: Date? = nil
    /// When Stripe ended the subscription (ended_at), nil while it runs.
    var endedAt: Date? = nil
    /// Set to cancel at the end of the current period.
    var cancelAtPeriodEnd: Bool? = nil
    /// Why it was cancelled (cancellation_details.reason): "payment_failed" when Stripe gave up charging.
    var cancelReason: String? = nil
    /// Its first paid invoice with money in it (status_transitions.paid_at).
    var firstPaid: Date? = nil
    /// True when the paid invoices were read: `firstPaid` nil then means it never paid. Nil in facts from before
    /// they were read (or with a key that can't read invoices): the old rule (paid for more than a day) applies.
    var invoicesRead: Bool? = nil
    /// Active, but its latest invoice is lost: uncollectible, or open after a failed charge with no retry left.
    var lastInvoiceLost: Bool? = nil

    /// Active and its latest invoice not lost: counts in the real MRR.
    var isActive: Bool { status == "active" && lastInvoiceLost != true }
    /// Payment failed: past_due, or active with a lost latest invoice. At risk, out of the real MRR.
    var atRisk: Bool { status == "past_due" || (status == "active" && lastInvoiceLost == true) }

    func pays(at t: Date) -> Bool { start <= t && (end.map { t < $0 } ?? true) }
    /// Has a paid invoice with money in it.
    var everPaid: Bool { invoicesRead == true ? firstPaid != nil : (end.map { $0.timeIntervalSince(start) > 86400 } ?? (status != "trialing")) }
    /// A paying customer: paid at least once, or active (a 100% coupon pays nothing and still counts).
    var paidOnce: Bool { everPaid || isActive }
}

extension SubFact {
    /// A made-up trial that never paid: cancelled by the customer during the trial, or closed by Stripe after the
    /// charge at its end failed. Still running when its end is ahead.
    static func demoUnpaidTrial(id: String, customer: String, price: Int, created: Date, trialEnd: Date, cancelAfter: TimeInterval,
                                failedPayment: Bool, now: Date) -> SubFact {
        let running = trialEnd > now
        if failedPayment {
            let closed = trialEnd.addingTimeInterval(7 * 86400)
            if running || closed > now {
                // Not over yet: a running trial, or a charge Stripe is still retrying
                return SubFact(id: id, customer: customer, who: nil, currency: "usd", monthly: price, start: trialEnd, end: running ? nil : trialEnd,
                               trialEnd: trialEnd, status: running ? "trialing" : "past_due", created: created, trialStart: created,
                               cancelAtPeriodEnd: false, invoicesRead: true)
            }
            return SubFact(id: id, customer: customer, who: nil, currency: "usd", monthly: price, start: trialEnd, end: trialEnd, trialEnd: trialEnd,
                           status: "canceled", created: created, canceledAt: closed, trialStart: created, endedAt: closed,
                           cancelAtPeriodEnd: false, cancelReason: "payment_failed", invoicesRead: true)
        }
        return SubFact(id: id, customer: customer, who: nil, currency: "usd", monthly: price, start: trialEnd, end: running ? nil : trialEnd,
                       trialEnd: trialEnd, status: running ? "trialing" : "canceled", created: created,
                       canceledAt: created.addingTimeInterval(cancelAfter), cancelAt: trialEnd, trialStart: created,
                       endedAt: running ? nil : trialEnd, cancelAtPeriodEnd: running, cancelReason: "cancellation_requested", invoicesRead: true)
    }
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
    /// `firstPaid`: each subscription's first paid invoice. With it, a subscription counts from that payment (or its
    /// trial end, or its start, for an active one paid with a 100% coupon) until Stripe ended it, and a past_due or
    /// unpaid one stops counting at the period it failed to pay; one that never paid never counts. Without it (a key
    /// that can't read invoices), the old rule: from the trial's end until it ended.
    static func fact(_ s: [String: Any], firstPaid: [String: Date]? = nil, now: Date = Date()) -> SubFact? {
        let status = s["status"] as? String ?? ""
        guard !["incomplete", "incomplete_expired"].contains(status) else { return nil }
        let cus = s["customer"] as? [String: Any]
        guard cus?["deleted"] as? Bool != true else { return nil }
        guard let top = monthlyValue(s).max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        func date(_ v: Any?) -> Date? { (v as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        let id = s["id"] as? String ?? ""
        let items = (s["items"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        // Newer API versions moved the billing period onto the items
        let periodStart = date(s["current_period_start"]) ?? date(items.first?["current_period_start"])
        let periodEnd = date(s["current_period_end"]) ?? date(items.first?["current_period_end"])
        let trialEnd = date(s["trial_end"])
        let started = date(s["start_date"]) ?? date(s["created"]) ?? now
        let endedAt = date(s["ended_at"])
        let lost = status == "active" && invoiceLost(s["latest_invoice"])
        var start = max(started, trialEnd ?? started)
        var end: Date?
        if let firstPaid {
            if let from = firstPaid[id] ?? (status == "active" && !lost ? (trialEnd ?? started) : nil) {
                start = from
                switch status {
                case "active" where lost: end = endedAt ?? periodStart ?? now
                case "active", "trialing": end = endedAt
                case "past_due", "unpaid", "paused": end = endedAt ?? periodStart ?? now
                default: end = endedAt ?? date(s["canceled_at"]) ?? start
                }
                if let e = end, e < start { end = start }
            } else {
                // Never paid: a running trial has its whole future ahead, anything else never counts
                end = status == "trialing" ? nil : start
            }
        } else {
            switch status {
            case "active" where lost: end = periodStart ?? start
            case "active", "trialing": end = nil
            case "past_due", "unpaid", "paused": end = periodStart ?? start
            default: end = endedAt ?? date(s["canceled_at"]) ?? start
            }
        }
        return SubFact(id: id, customer: cus?["id"] as? String ?? (s["customer"] as? String ?? ""),
                       who: person(name: cus?["name"] as? String, email: cus?["email"] as? String),
                       email: (cus?["email"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
                       currency: top.key, monthly: top.value, start: start, end: end, trialEnd: trialEnd, status: status,
                       created: started, canceledAt: date(s["canceled_at"]),
                       cancelAt: date(s["cancel_at"]) ?? (s["cancel_at_period_end"] as? Bool == true ? periodEnd : nil),
                       trialStart: date(s["trial_start"]), endedAt: endedAt, cancelAtPeriodEnd: s["cancel_at_period_end"] as? Bool == true,
                       cancelReason: (s["cancellation_details"] as? [String: Any])?["reason"] as? String,
                       firstPaid: firstPaid?[id], invoicesRead: firstPaid != nil ? true : nil, lastInvoiceLost: lost ? true : nil)
    }

    /// A latest invoice Stripe gave up on: uncollectible, or open after a failed charge with no retry planned.
    /// Only readable when `latest_invoice` is expanded (an id alone says nothing).
    static func invoiceLost(_ v: Any?) -> Bool {
        guard let inv = v as? [String: Any] else { return false }
        switch inv["status"] as? String {
        case "uncollectible": return true
        case "open": return (inv["attempt_count"] as? Int ?? 0) >= 1 && !(inv["next_payment_attempt"] is Int)
        default: return false
        }
    }

    /// Each subscription's first paid invoice with money in it, from a list of paid invoices.
    /// The subscription is `invoice.subscription` in older API versions, `invoice.parent.subscription_details.subscription` in newer ones.
    static func firstPaidBySub(_ invoices: [[String: Any]]) -> [String: Date] {
        var out: [String: Date] = [:]
        for inv in invoices {
            let parent = (inv["parent"] as? [String: Any])?["subscription_details"] as? [String: Any]
            let ref = inv["subscription"] ?? parent?["subscription"]
            let sub = (ref as? String) ?? ((ref as? [String: Any])?["id"] as? String)
            guard let sub, (inv["amount_paid"] as? Int ?? 0) > 0,
                  let at = (inv["status_transitions"] as? [String: Any])?["paid_at"] as? Int else { continue }
            let d = Date(timeIntervalSince1970: TimeInterval(at))
            out[sub] = min(out[sub] ?? d, d)
        }
        return out
    }

    /// Paid invoices created since `since` (all of them when nil), read into each subscription's first payment.
    func firstPaid(since: Date?) async throws -> [String: Date] {
        var q: [(String, String)] = [("status", "paid")]
        if let since { q.append(("created[gte]", String(Int(since.timeIntervalSince1970)))) }
        return Self.firstPaidBySub(try await list("invoices", q, max: 200_000))
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
    /// One day of churn: the share of the customers paying 30 days earlier who no longer pay, and who left that day.
    struct ChurnDay: Identifiable { let date: Date; let rate: Double?; let lost: Int; let base: Int; var id: Date { date } }

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
    var churn: [ChurnDay] = []
    /// Paying customers lost in the last 30 days, out of the ones who paid during the window (the money in the display currency).
    var churnNow = Churn30()
    /// Active subscriptions set to cancel: lost soon unless they change their mind.
    var cancelling = 0
    var cancellingMrr = 0
    /// Customers who ever paid, and how many of them no longer do.
    var everPaid = 0
    var lostAllTime = 0
    /// Average net new MRR a month over the last 3 full months.
    var pace: Int?

    var mrr: Int { last30.endMrr }
    var customers: Int { last30.endCustomers }
    var arpu: Int { customers > 0 ? mrr / customers : 0 }
    var growth: Double? { last30.startMrr > 0 ? Double(last30.endMrr - last30.startMrr) / Double(last30.startMrr) : nil }
    /// Paying customers lost in the last 30 days, out of the ones who paid during the window.
    var customerChurn: Double? { churnNow.rate }
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

    /// A project whose subscriptions live outside Stripe (RevenueCat): its MRR by day and its subscribers now.
    struct Outside {
        let mrr: [Date: Int]
        let subscribers: Int
        /// The MRR on the last known day at or before `t`.
        func at(_ t: Date) -> Int { mrr.filter { $0.key <= t }.max(by: { $0.key < $1.key })?.value ?? 0 }
    }

    /// `accounts` is what the window looks at (one project or all); `all` feeds the per-project table.
    static func build(accounts: [Account], all: [Account], facts: [UUID: [SubFact]], revenue: [UUID: [Date: [String: Int]]],
                      failed: [UUID: [FailedInvoice]], months: Int, convert: (Int, String) -> Int,
                      outside: [UUID: Outside] = [:], now: Date = Date()) -> DashboardData {
        func items(_ accs: [Account]) -> [Item] {
            accs.flatMap { a in (facts[a.id] ?? []).map { Item(account: a.id, key: a.id.uuidString + "|" + (($0.email?.isEmpty == false ? $0.email : nil) ?? $0.customer), monthly: convert($0.monthly, $0.currency), fact: $0) } }
        }
        let list = items(accounts)
        let cal = Calendar.current
        let day: TimeInterval = 86400
        var d = DashboardData()

        // The MRR curve: one point a week, per project (a day over a single month)
        let step: Double = months <= 1 ? 1 : 7
        let points = Int((Double(months) * 30.44 / step).rounded())
        for w in stride(from: points, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(w) * step * day)
            var per: [UUID: Int] = [:]
            for it in list where it.fact.pays(at: t) { per[it.account, default: 0] += it.monthly }
            for (id, o) in outside { per[id] = o.at(t) }
            for a in accounts { d.series.append(.init(date: t, account: a.id, value: per[a.id] ?? 0)) }
        }

        // Where the MRR came from and went, calendar month by calendar month (this one so far)
        // (over a single month, week by week: one bar would say little)
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        var calendarMonths: [DashboardData.Month] = []
        for m in stride(from: max(months, 4) - 1, through: 0, by: -1) {
            let a = cal.date(byAdding: .month, value: -m, to: thisMonth)!
            let b = m == 0 ? now : cal.date(byAdding: .month, value: 1, to: a)!
            calendarMonths.append(.init(month: a, move: movement(list, a, b)))
        }
        if months <= 1 {
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
            for w in stride(from: 4, through: 0, by: -1) {
                let a = cal.date(byAdding: .weekOfYear, value: -w, to: thisWeek)!
                let b = w == 0 ? now : cal.date(byAdding: .weekOfYear, value: 1, to: a)!
                d.months.append(.init(month: a, move: movement(list, a, b)))
            }
        } else {
            d.months = Array(calendarMonths.suffix(months))
        }
        d.last30 = movement(list, now.addingTimeInterval(-30 * day), now)
        d.last90 = movement(list, now.addingTimeInterval(-90 * day), now)
        // RevenueCat projects count in the MRR and its growth; their customers' moves stay in RevenueCat
        for o in outside.values {
            d.last30.startMrr += o.at(now.addingTimeInterval(-30 * day)); d.last30.endMrr += o.at(now)
            d.last30.endCustomers += o.subscribers
        }
        let full = calendarMonths.dropLast().suffix(3)
        if !full.isEmpty { d.pace = full.reduce(0) { $0 + $1.move.net } / full.count }

        // Trials that ended in the last 90 days, one per customer, and how many of them paid
        let ended = accounts.flatMap { Metrics.endedTrials(facts[$0.id] ?? [], now: now, since: now.addingTimeInterval(-90 * day)) }
        d.trialsEnded = ended.count
        if !ended.isEmpty { d.trialConversion = Double(ended.filter { $0.outcome == .paying }.count) / Double(ended.count) }

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

        // Churn of paying customers: lost in the last 30 days out of the ones who paid during the window, day by day
        // over the last 90 days, with the customers lost each day. A trial that never paid is not churn.
        let customers = Metrics.payingCustomers(list.map { ($0.key, $0.fact) }, now: now, amount: { convert($0.monthly, $0.currency) })
        let today = cal.startOfDay(for: now)
        for k in stride(from: 90, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -k, to: today)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let c = Metrics.churn30(customers, at: k == 0 ? now : min(now, next.addingTimeInterval(-1)))
            let lost = customers.filter { $0.lostAt.map { $0 >= day && $0 < next } ?? false }.count
            d.churn.append(.init(date: day, rate: c.rate, lost: lost, base: c.base.count))
        }
        d.churnNow = Metrics.churn30(customers, at: now)
        let leaving = list.filter { $0.fact.isActive && Metrics.isCancelling($0.fact) }
        d.cancelling = leaving.count
        d.cancellingMrr = leaving.reduce(0) { $0 + $1.monthly }
        d.everPaid = customers.count
        d.lostAllTime = customers.filter { $0.lostAt != nil }.count

        for a in all {
            if let o = outside[a.id] {
                let start = o.at(now.addingTimeInterval(-30 * day)), end = o.at(now)
                d.projects.append(.init(id: a.id, mrr: end, growth: start > 0 ? Double(end - start) / Double(start) : nil,
                                        customers: o.subscribers, churn: nil, arpu: o.subscribers > 0 ? end / o.subscribers : 0))
                continue
            }
            let its = items([a])
            let m = movement(its, now.addingTimeInterval(-30 * day), now)
            let churn = Metrics.churn30(Metrics.payingCustomers(its.map { ($0.key, $0.fact) }, now: now), at: now)
            d.projects.append(.init(id: a.id, mrr: m.endMrr,
                                    growth: m.startMrr > 0 ? Double(m.endMrr - m.startMrr) / Double(m.startMrr) : nil,
                                    customers: m.endCustomers,
                                    churn: churn.rate,
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

/// Trials and where they lead, the way the Viewlify admin board reads them: the real MRR day by day, the days' new
/// trials, new payers and cancelled trials, then the coming days until the last running trial ends, once if every
/// trial pays and once with each trial weighted by the pay rate of its project's ended trials at its age.
/// Paying subscriptions set to cancel stop counting on their date; past_due ones are left out.
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
    /// What the running trials should bring: each one x the pay rate at its age.
    var expected = 0
    /// Real MRR + expected. Nil until a trial has ended (no history, no rate).
    var projected: Int?
    var ended = 0, endedPaying = 0, endedFailed = 0, endedCancelled = 0
    /// The share of the running trials' MRR expected to pay.
    var rate: Double? { projected != nil && trials > 0 ? Double(expected) / Double(trials) : nil }
    /// The last running trial's end, and the MRR then if every trial pays.
    var horizon: Date?
    var allAtHorizon: Int?
    var hasFuture: Bool { days.contains { $0.all != nil } }

    static func build(accounts: [Account], facts: [UUID: [SubFact]], convert: (Int, String) -> Int,
                      now: Date = Date(), back: Int = 30, maxAhead: Int = 60) -> Projection {
        let cal = Calendar.current
        let day: TimeInterval = 86400
        var p = Projection()
        let today = cal.startOfDay(for: now)
        func endOfDay(_ d: Date) -> Date { min(now, cal.date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-1)) }

        struct Item { let account: UUID; let monthly: Int; let fact: SubFact }
        let items = accounts.flatMap { a in (facts[a.id] ?? []).map { Item(account: a.id, monthly: convert($0.monthly, $0.currency), fact: $0) } }
        // Each project's ended trials, one per customer: its running trials are weighed against its own history
        let ended = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, Metrics.endedTrials(facts[$0.id] ?? [], now: now)) })

        // The past, one point a day
        for k in stride(from: back, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -k, to: today)!
            let t = k == 0 ? now : endOfDay(d)
            var row = Day(date: d)
            row.real = items.filter { $0.fact.pays(at: t) }.reduce(0) { $0 + $1.monthly }
            for it in items {
                if it.fact.trialEnd != nil, let c = it.fact.created, cal.isDate(c, inSameDayAs: d) { row.newTrials += 1 }
                if it.fact.paidOnce, cal.isDate(it.fact.start, inSameDayAs: d), it.fact.start <= now { row.newPaying += 1 }
                // Cancelled by the customer while in trial; a failed payment at the trial's end is not a cancellation
                if let te = it.fact.trialEnd, let c = it.fact.canceledAt, c <= te, it.fact.cancelReason != "payment_failed",
                   cal.isDate(c, inSameDayAs: d) { row.cancelledTrials += 1 }
            }
            p.days.append(row)
        }
        p.real = p.days.last?.real ?? 0
        if p.days.count > 7 { p.real7Ago = p.days[p.days.count - 8].real }

        // Running trials that aren't set to cancel (each subscription counts), and the ones that are
        let trialing = items.filter { $0.fact.status == "trialing" }
        let live = trialing.filter { !Metrics.isCancelling($0.fact) }
        let rate = Dictionary(uniqueKeysWithValues: live.map { it in
            (it.fact.id + it.account.uuidString, Metrics.payRateAtAge(ended[it.account] ?? [], Metrics.trialAge(it.fact, now: now)) ?? 0) })
        func weight(_ it: Item) -> Double { Double(it.monthly) * (rate[it.fact.id + it.account.uuidString] ?? 0) }
        p.trials = live.reduce(0) { $0 + $1.monthly }
        p.trialCount = live.count
        p.trialsCancelling = trialing.count - live.count
        p.expected = Int(live.reduce(0.0) { $0 + weight($1) }.rounded())
        if ended.values.contains(where: { !$0.isEmpty }) { p.projected = p.real + p.expected }

        let pastDue = items.filter { $0.fact.atRisk }
        p.atRisk = pastDue.reduce(0) { $0 + $1.monthly }
        p.atRiskCount = pastDue.count
        for e in ended.values {
            p.ended += e.count
            p.endedPaying += e.filter { $0.outcome == .paying }.count
            p.endedFailed += e.filter { $0.outcome == .paymentFailed }.count
            p.endedCancelled += e.filter { $0.outcome == .cancelled }.count
        }

        // The future, to the last running trial's end
        let paying = items.filter { $0.fact.isActive }
        let ends = live.compactMap(\.fact.trialEnd).filter { $0 > now }
        if let last = ends.max() {
            let horizon = min(last, now.addingTimeInterval(Double(maxAhead) * day))
            p.horizon = horizon
            // Today's point opens the dashed lines, so they leave from the real curve
            if let i = p.days.indices.last { p.days[i].all = p.real; p.days[i].atRate = p.real }
            var d = cal.date(byAdding: .day, value: 1, to: today)!
            while d <= horizon {
                let t = cal.date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-1)
                let base = paying.filter { !Metrics.isCancelling($0.fact) || ($0.fact.cancelAt.map { t < $0 } ?? true) }.reduce(0) { $0 + $1.monthly }
                let joined = live.filter { ($0.fact.trialEnd ?? .distantFuture) <= t }
                let all = base + joined.reduce(0) { $0 + $1.monthly }
                let atRate = base + Int(joined.reduce(0.0) { $0 + weight($1) }.rounded())
                p.days.append(Day(date: d, all: all, atRate: atRate))
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            p.allAtHorizon = p.days.last?.all
        }
        return p
    }
}
