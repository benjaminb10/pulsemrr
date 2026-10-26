// The MRR rules, the way the Viewlify admin board reads Stripe (src/lib/stripe/trial-conversion.ts, mrr.server.ts):
// pure functions on SubFacts, unit-tested (Tests/run.sh) and ported line by line to the cloud (src/lib/metrics).
//  - Real MRR: active subscriptions only. At risk: past_due, or active with a latest invoice Stripe gave up on. Trials: trialing and not set to cancel, each subscription counts.
//  - Projection: real MRR + each running trial x the pay rate of the ended trials that reached its age without cancelling.
//  - Churn: paying customers only (a trial that never paid is not churn).
import Foundation

enum TrialOutcome: String, Codable { case paying, paymentFailed, cancelled }

struct EndedTrial: Equatable {
    let outcome: TrialOutcome
    /// Seconds between the trial's start and the customer's cancel request (cancelled only).
    let cancelAge: TimeInterval?
}

/// A customer who paid at least once: since when, and when they stopped (nil while they pay).
struct PayingCustomer {
    let key: String
    let from: Date
    let lostAt: Date?
    /// Their last subscription to end: its amount is the MRR lost, its reason tells a failed payment from a cancellation.
    let lastEnded: SubFact?
    /// The amount lost, in whatever unit the caller gave (minor units of the display currency for the dashboard).
    let lostMrr: Int
    var paymentFailed: Bool { lastEnded?.cancelReason == "payment_failed" }
}

struct Churn30 {
    var base: [PayingCustomer] = []
    var lost: [PayingCustomer] = []
    var rate: Double? { base.isEmpty ? nil : Double(lost.count) / Double(base.count) }
}

enum Metrics {
    static let day: TimeInterval = 86400

    /// One person: the email when Stripe has one (two Stripe customers, one person), the customer id otherwise.
    static func customerKey(_ f: SubFact) -> String { (f.email?.isEmpty == false ? f.email : nil) ?? f.customer }

    /// Set to cancel: at the end of the period, or at a date (a trial's cancel date at or before its end).
    static func isCancelling(_ f: SubFact) -> Bool {
        if f.cancelAtPeriodEnd == true { return true }
        guard let c = f.cancelAt else { return false }
        if f.status == "trialing", let te = f.trialEnd { return c <= te }
        return true
    }

    /// How old a running trial is: now minus its start (the subscription's start without one).
    static func trialAge(_ f: SubFact, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(f.trialStart ?? f.created ?? now))
    }

    /// One customer's ended trial(s). Paid at least once (or still active) = paying, even if they left later: that
    /// departure is churn. A subscription Stripe closed after failed charges, or one cancelled only after its trial
    /// ended without paying, is a payment failure, not a choice of the customer.
    static func classifyEndedTrial(_ subs: [SubFact]) -> EndedTrial {
        if subs.contains(where: { $0.isActive || $0.everPaid }) { return EndedTrial(outcome: .paying, cancelAge: nil) }
        if subs.contains(where: { $0.atRisk || $0.status == "unpaid" }) { return EndedTrial(outcome: .paymentFailed, cancelAge: nil) }
        var ages: [TimeInterval] = []
        var failed = false
        for s in subs {
            if s.cancelReason == "payment_failed" || (s.canceledAt != nil && s.trialEnd != nil && s.canceledAt! >= s.trialEnd!) {
                failed = true
                continue
            }
            if let c = s.canceledAt, let start = s.trialStart ?? s.created { ages.append(max(0, c.timeIntervalSince(start))) } else { ages.append(0) }
        }
        if failed && ages.isEmpty { return EndedTrial(outcome: .paymentFailed, cancelAge: nil) }
        return EndedTrial(outcome: .cancelled, cancelAge: ages.min() ?? 0)
    }

    /// Chance that a trial still running at `age` (and not cancelled so far) ends up paying: paying / ended trials that
    /// had not been cancelled by that age. Failed payments stay in the denominator. A brand-new trial gets the plain rate.
    static func payRateAtAge(_ ended: [EndedTrial], _ age: TimeInterval) -> Double? {
        let pool = age <= 0 ? ended : ended.filter { !($0.outcome == .cancelled && ($0.cancelAge ?? 0) <= age) }
        guard !pool.isEmpty else { return nil }
        return Double(pool.filter { $0.outcome == .paying }.count) / Double(pool.count)
    }

    /// Trials whose end has passed, one outcome per customer (a second trial of the same person counts once).
    static func endedTrials(_ facts: [SubFact], now: Date, since: Date? = nil) -> [EndedTrial] {
        var byCustomer: [String: [SubFact]] = [:]
        for f in facts {
            guard let te = f.trialEnd, te <= now else { continue }
            byCustomer[customerKey(f), default: []].append(f)
        }
        return byCustomer.values.compactMap { list in
            // `since`: only customers whose last trial ended after that date (the dashboard's 90-day conversion)
            if let since, (list.compactMap(\.trialEnd).max() ?? .distantPast) <= since { return nil }
            return classifyEndedTrial(list)
        }
    }

    /// Paying customers, one per key. A customer counts once they paid (a paid invoice, or an active subscription paid
    /// with a 100% coupon). They are lost when none of their paid subscriptions is still active or past_due; the date is
    /// the end of the last one to end. `amount` gives what a subscription weighs (converted or not).
    static func payingCustomers(_ items: [(key: String, fact: SubFact)], now: Date, amount: (SubFact) -> Int = \.monthly) -> [PayingCustomer] {
        var byKey: [String: [SubFact]] = [:]
        for it in items where it.fact.paidOnce { byKey[it.key, default: []].append(it.fact) }
        return byKey.map { key, paid in
            let still = paid.contains { $0.status == "active" || $0.status == "past_due" }
            func ended(_ f: SubFact) -> Date? { f.endedAt ?? (f.status == "active" || f.status == "past_due" ? nil : f.end) }
            let last = paid.filter { ended($0) != nil }.max { ended($0)! < ended($1)! }
            return PayingCustomer(key: key, from: paid.map(\.start).min() ?? now,
                                  lostAt: still ? nil : (last.flatMap(ended) ?? now),
                                  lastEnded: last, lostMrr: last.map(amount) ?? 0)
        }
    }

    /// Lost in (t - 30 days, t], out of the customers paying at some point in that window.
    static func churn30(_ customers: [PayingCustomer], at t: Date) -> Churn30 {
        let since = t.addingTimeInterval(-30 * day)
        let base = customers.filter { $0.from <= t && ($0.lostAt.map { $0 > since } ?? true) }
        return Churn30(base: base, lost: base.filter { ($0.lostAt.map { $0 <= t }) ?? false })
    }
}

extension MrrSnapshot {
    /// The snapshot of one project from its subscriptions (deleted customers and excluded emails already left out).
    static func from(_ facts: [SubFact], now: Date = Date()) -> MrrSnapshot {
        var s = MrrSnapshot()
        func add(_ m: inout [String: Int], _ f: SubFact) { m[f.currency, default: 0] += f.monthly }
        let ended = Metrics.endedTrials(facts, now: now)
        var expected: [String: Double] = [:]
        for f in facts {
            if f.atRisk {
                add(&s.atRisk, f); s.atRiskCount += 1
                s.failing.append(FailingSub(id: f.id, who: f.who, amount: f.monthly, currency: f.currency, since: f.end ?? f.start))
                continue
            }
            switch f.status {
            case "active":
                add(&s.real, f); s.activeCount += 1
                if Metrics.isCancelling(f) { add(&s.leaving, f); s.leavingCount += 1 }
            case "trialing":
                if Metrics.isCancelling(f) { s.trialsCancelling += 1; continue }
                add(&s.trials, f); s.trialCount += 1
                expected[f.currency, default: 0] += Double(f.monthly) * (Metrics.payRateAtAge(ended, Metrics.trialAge(f, now: now)) ?? 0)
            default: break
            }
        }
        s.expected = expected.mapValues { Int($0.rounded()) }
        s.trialsEnded = ended.count
        s.trialsPaying = ended.filter { $0.outcome == .paying }.count
        s.trialsFailed = ended.filter { $0.outcome == .paymentFailed }.count
        s.trialsCancelled = ended.filter { $0.outcome == .cancelled }.count
        let customers = Metrics.payingCustomers(facts.map { (Metrics.customerKey($0), $0) }, now: now)
        let c = Metrics.churn30(customers, at: now)
        s.churnBase = c.base.count; s.churnLost = c.lost.count
        s.churnFailed = c.lost.filter(\.paymentFailed).count; s.churnCancelled = s.churnLost - s.churnFailed
        for l in c.lost { if let f = l.lastEnded { add(&s.churnLostMrr, f) } }
        s.everPaid = customers.count
        s.lostAllTime = customers.filter { $0.lostAt != nil }.count
        return s
    }
}
