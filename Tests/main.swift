// Unit tests of the MRR rules. Run: Tests/run.sh
// The trial cases are Viewlify's own (src/lib/stripe/trial-conversion.test.ts), then one test per rule and per trap.
import Foundation

var failures = 0, passed = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { passed += 1 } else { failures += 1; print("FAIL line \(line): \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) { check(a == b, "\(what): \(a) != \(b)", line: line) }
func close(_ a: Double?, _ b: Double?, _ what: String, line: Int = #line) {
    switch (a, b) {
    case (nil, nil): passed += 1
    case let (x?, y?): check(abs(x - y) < 1e-9, "\(what): \(x) != \(y)", line: line)
    default: check(false, "\(what): \(String(describing: a)) != \(String(describing: b))", line: line)
    }
}

let DAY: TimeInterval = 86400
let now = Date(timeIntervalSince1970: 1_793_016_000)
func at(_ days: Double) -> Date { now.addingTimeInterval(days * DAY) }
func t(_ secs: Double) -> Date { Date(timeIntervalSince1970: secs) }

/// A subscription for the tests: invoices read, so `paid` decides whether it ever paid.
func sub(_ status: String, id: String = UUID().uuidString, customer: String = UUID().uuidString, monthly: Int = 1000, currency: String = "eur",
         trialStart: Date? = nil, trialEnd: Date? = nil, canceledAt: Date? = nil, reason: String? = nil, paid: Date? = nil,
         endedAt: Date? = nil, cancelAtPeriodEnd: Bool = false, cancelAt: Date? = nil, created: Date? = nil) -> SubFact {
    let start = paid ?? (status == "active" ? (trialEnd ?? created ?? at(-60)) : (trialEnd ?? created ?? at(-60)))
    let never = paid == nil && status != "active"
    // as fact() reads it: a past_due or unpaid one stopped counting at the period it failed to pay
    let failing = status == "past_due" || status == "unpaid"
    let end: Date? = status == "trialing" ? nil : (endedAt ?? (never ? start : failing ? max(start, at(-5)) : nil))
    return SubFact(id: id, customer: customer, who: nil, currency: currency, monthly: monthly, start: start, end: end, trialEnd: trialEnd,
                   status: status, created: created ?? trialStart, canceledAt: canceledAt, cancelAt: cancelAt, trialStart: trialStart,
                   endedAt: endedAt, cancelAtPeriodEnd: cancelAtPeriodEnd, cancelReason: reason, firstPaid: paid, invoicesRead: true)
}

// MARK: classifyEndedTrial (Viewlify's cases)

do {
    let paidThenLeft = Metrics.classifyEndedTrial([sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(120 * DAY),
                                                       reason: "cancellation_requested", paid: t(14 * DAY), endedAt: t(120 * DAY))])
    eq(paidThenLeft.outcome, .paying, "a trial paid once then cancelled months later converted (its departure is churn)")
    eq(Metrics.classifyEndedTrial([sub("canceled", reason: "payment_failed", paid: t(14 * DAY), endedAt: t(60 * DAY))]).outcome, .paying,
       "paid once, then closed after failed charges: still converted")
    eq(Metrics.classifyEndedTrial([sub("canceled"), sub("active")]).outcome, .paying, "paying beats everything")
    eq(Metrics.classifyEndedTrial([sub("canceled", reason: "payment_failed")]).outcome, .paymentFailed, "closed after failed charges")
    eq(Metrics.classifyEndedTrial([sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(21 * DAY))]).outcome, .paymentFailed,
       "cancelled after the trial ended without paying = payment failure")
    eq(Metrics.classifyEndedTrial([sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(3 * DAY), reason: "cancellation_requested")]),
       EndedTrial(outcome: .cancelled, cancelAge: 3 * DAY), "cancel during the trial keeps its age")
    eq(Metrics.classifyEndedTrial([sub("past_due", trialEnd: t(14 * DAY))]).outcome, .paymentFailed, "past_due = payment failed")
    eq(Metrics.classifyEndedTrial([sub("unpaid", trialEnd: t(14 * DAY))]).outcome, .paymentFailed, "unpaid = payment failed")
    eq(Metrics.classifyEndedTrial([sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(5 * DAY), reason: "cancellation_requested"),
                                   sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(2 * DAY), reason: "cancellation_requested")]),
       EndedTrial(outcome: .cancelled, cancelAge: 2 * DAY), "two cancelled trials: the smallest age")
    eq(Metrics.classifyEndedTrial([sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(20 * DAY), reason: "payment_failed"),
                                   sub("canceled", trialStart: t(0), trialEnd: t(14 * DAY), canceledAt: t(4 * DAY), reason: "cancellation_requested")]),
       EndedTrial(outcome: .cancelled, cancelAge: 4 * DAY), "a failure and a cancellation: cancelled")
}

// MARK: payRateAtAge (Viewlify's cases)

do {
    let ended = [EndedTrial(outcome: .paying, cancelAge: nil), EndedTrial(outcome: .paymentFailed, cancelAge: nil),
                 EndedTrial(outcome: .cancelled, cancelAge: 600), EndedTrial(outcome: .cancelled, cancelAge: 5 * DAY)]
    close(Metrics.payRateAtAge(ended, 0), 1.0 / 4, "a brand-new trial gets the plain historical rate")
    close(Metrics.payRateAtAge(ended, DAY), 1.0 / 3, "surviving past a cancel age drops it from the pool")
    close(Metrics.payRateAtAge(ended, 6 * DAY), 1.0 / 2, "and the next one")
    close(Metrics.payRateAtAge([], DAY), nil, "no history, no rate")
}

// MARK: the trap: 9 "cancellations" that are in fact failed payments

do {
    var facts: [SubFact] = []
    for i in 0..<9 {
        // Stripe status canceled, closed a week after the trial ended because the card was declined
        facts.append(sub("canceled", customer: "cus_f\(i)", trialStart: at(-40), trialEnd: at(-26), canceledAt: at(-19),
                         reason: i % 2 == 0 ? "payment_failed" : nil, endedAt: at(-19)))
    }
    facts.append(sub("active", customer: "cus_paid", trialStart: at(-40), trialEnd: at(-26), paid: at(-26)))
    let ended = Metrics.endedTrials(facts, now: now)
    eq(ended.filter { $0.outcome == .paymentFailed }.count, 9, "9 canceled subscriptions are failed payments")
    eq(ended.filter { $0.outcome == .cancelled }.count, 0, "none of them is a customer's cancellation")
    // Failed payments stay in the denominator at every age: 1 in 10, not 1 in 1
    close(Metrics.payRateAtAge(ended, 0), 0.1, "rate at age 0")
    close(Metrics.payRateAtAge(ended, 10 * DAY), 0.1, "rate at 10 days: failures are not dropped like cancellations")
}

// MARK: snapshot: real MRR, at risk, trials, projection

do {
    let facts = [
        sub("active", customer: "a", monthly: 2900, paid: at(-50)),
        sub("active", customer: "b", monthly: 4900, paid: at(-20), cancelAtPeriodEnd: true, cancelAt: at(10)),
        sub("past_due", customer: "c", monthly: 9900, paid: at(-80), endedAt: nil),
        sub("unpaid", customer: "d", monthly: 1500, paid: at(-200)),
        // two trials of one customer: each subscription counts for the money
        sub("trialing", customer: "e", monthly: 1000, trialStart: at(-2), trialEnd: at(12)),
        sub("trialing", customer: "e", monthly: 1000, trialStart: at(-2), trialEnd: at(12)),
        // set to cancel: out of the trials, counted apart
        sub("trialing", customer: "f", monthly: 1000, trialStart: at(-5), trialEnd: at(9), cancelAtPeriodEnd: true, cancelAt: at(9)),
        // the newer dashboards set cancel_at only
        sub("trialing", customer: "g", monthly: 1000, trialStart: at(-5), trialEnd: at(9), cancelAt: at(9)),
        // history: one paid, one cancelled on day 1, one failed payment
        sub("active", customer: "h", monthly: 2000, trialStart: at(-60), trialEnd: at(-46), paid: at(-46)),
        sub("canceled", customer: "i", trialStart: at(-60), trialEnd: at(-46), canceledAt: at(-59), reason: "cancellation_requested", endedAt: at(-46)),
        sub("canceled", customer: "j", trialStart: at(-60), trialEnd: at(-46), canceledAt: at(-39), reason: "payment_failed", endedAt: at(-39)),
    ]
    let s = MrrSnapshot.from(facts, now: now)
    eq(s.real["eur"], 2900 + 4900 + 2000, "real MRR = active only")
    eq(s.activeCount, 3, "active count")
    eq(s.atRisk["eur"], 9900, "at risk = past_due only")
    eq(s.atRiskCount, 1, "unpaid is not at risk")
    eq(s.leavingCount, 1, "active set to cancel")
    eq(s.trialCount, 2, "each running trial counts, duplicates included")
    eq(s.trials["eur"], 2000, "trials MRR")
    eq(s.trialsCancelling, 2, "cancelling trials apart (cancel_at_period_end or cancel_at)")
    eq(s.trialsEnded, 3, "ended trials, one per customer")
    eq([s.trialsPaying, s.trialsFailed, s.trialsCancelled], [1, 1, 1], "outcomes")
    // Running trials are 2 days old: the cancel at age 1 day is out of the pool -> 1 paying of 2
    eq(s.expected["eur"], 1000, "expected = trials x pay rate at their age")
    close(s.conversion, 0.5, "displayed rate = expected / trials")
}

do {
    let s = MrrSnapshot.from([sub("active", monthly: 1000, paid: at(-10)), sub("trialing", trialStart: at(-1), trialEnd: at(13))], now: now)
    close(s.conversion, nil, "no ended trial: no rate")
    eq(s.expected.values.reduce(0, +), 0, "no ended trial: nothing expected")
}

// MARK: churn

do {
    let facts = [
        sub("active", customer: "stay", paid: at(-100)),
        // left 10 days ago after cancelling
        sub("canceled", customer: "left", monthly: 2500, canceledAt: at(-15), reason: "cancellation_requested", paid: at(-100), endedAt: at(-10)),
        // Stripe gave up charging 5 days ago
        sub("canceled", customer: "failed", monthly: 1200, reason: "payment_failed", paid: at(-90), endedAt: at(-5)),
        // left 40 days ago: outside the window and out of its base
        sub("canceled", customer: "old", paid: at(-200), endedAt: at(-40)),
        // past_due is at risk, not lost
        sub("past_due", customer: "late", paid: at(-60)),
        // a trial that never paid is not churn
        sub("canceled", customer: "trial", trialStart: at(-20), trialEnd: at(-6), canceledAt: at(-18), reason: "cancellation_requested", endedAt: at(-6)),
        // an active subscription on a 100% coupon (no paid invoice) is a paying customer
        sub("active", customer: "free", trialEnd: at(-30)),
        // two subscriptions, one still active: not lost
        sub("canceled", customer: "two", paid: at(-80), endedAt: at(-3)),
        sub("active", customer: "two", paid: at(-3)),
        // set to cancel: soon lost
        sub("active", customer: "soon", paid: at(-50), cancelAtPeriodEnd: true, cancelAt: at(5)),
    ]
    let s = MrrSnapshot.from(facts, now: now)
    eq(s.churnLost, 2, "lost in 30 days")
    eq(s.churnBase, 7, "base: paying at some point in the window (stay, left, failed, late, free, two, soon)")
    eq(s.churnFailed, 1, "payment_failed is a failed payment")
    eq(s.churnCancelled, 1, "anything else a cancellation")
    eq(s.churnLostMrr["eur"], 3700, "MRR lost")
    eq(s.everPaid, 8, "customers who ever paid (the trial is not one)")
    eq(s.lostAllTime, 3, "lost since the start")
    eq(s.leavingCount, 1, "set to cancel")
    let customers = Metrics.payingCustomers(facts.map { (Metrics.customerKey($0), $0) }, now: now)
    close(Metrics.churn30(customers, at: at(-20)).rate, 1.0 / 8, "rolling churn 20 days ago: old lost, out of the 8 paying in (-50, -20]")
}

// MARK: reading Stripe

do {
    let invoices: [[String: Any]] = [
        ["subscription": "sub_old", "amount_paid": 1000, "status_transitions": ["paid_at": 2000]],
        ["subscription": "sub_old", "amount_paid": 1000, "status_transitions": ["paid_at": 1000]],
        ["subscription": "sub_zero", "amount_paid": 0, "status_transitions": ["paid_at": 1000]],
        ["parent": ["subscription_details": ["subscription": "sub_new"]], "amount_paid": 500, "status_transitions": ["paid_at": 3000]],
        ["subscription": ["id": "sub_expanded"], "amount_paid": 500, "status_transitions": ["paid_at": 4000]],
        ["amount_paid": 500, "status_transitions": ["paid_at": 4000]],
    ]
    let m = StripeClient.firstPaidBySub(invoices)
    eq(m["sub_old"], t(1000), "first paid invoice (invoice.subscription)")
    eq(m["sub_new"], t(3000), "newer API: invoice.parent.subscription_details.subscription")
    eq(m["sub_expanded"], t(4000), "expanded subscription")
    eq(m["sub_zero"], nil, "a zero invoice is not a payment")
    eq(m.count, 3, "one-off invoices left out")

    let raw: [String: Any] = ["id": "sub_y", "status": "active", "customer": ["id": "cus_y", "email": "Y@x.com"], "start_date": 1000,
                              "items": ["data": [["quantity": 2, "price": ["unit_amount": 12000, "currency": "eur", "recurring": ["interval": "year"]]]]],
                              "discount": ["coupon": ["percent_off": 50]]]
    eq(StripeClient.monthlyValue(raw), ["eur": 2000], "list price: yearly / 12 x quantity, coupons ignored")
    let free = StripeClient.fact(raw, firstPaid: [:], now: now)!
    eq(free.start, t(1000), "active without a paid invoice counts from its start")
    check(free.paidOnce, "an active 100% coupon is a paying customer")
    eq(free.email, "y@x.com", "email lowercased")

    let pastDue: [String: Any] = ["id": "sub_p", "status": "past_due", "customer": "cus_p", "start_date": 1000,
                                  "items": ["data": [["current_period_start": 9000, "price": ["unit_amount": 1000, "currency": "eur", "recurring": ["interval": "month"]]]]]]
    let pd = StripeClient.fact(pastDue, firstPaid: ["sub_p": t(2000)], now: now)!
    eq(pd.start, t(2000), "counts from its first payment")
    eq(pd.end, t(9000), "past_due stops at current_period_start (on the items in newer API versions)")

    let never: [String: Any] = ["id": "sub_n", "status": "canceled", "customer": "cus_n", "start_date": 1000, "trial_start": 1000, "trial_end": 5000,
                                "ended_at": 5000, "canceled_at": 2000, "cancellation_details": ["reason": "cancellation_requested"],
                                "items": ["data": [["price": ["unit_amount": 1000, "currency": "eur", "recurring": ["interval": "month"]]]]]]
    let n = StripeClient.fact(never, firstPaid: [:], now: now)!
    check(!n.pays(at: t(6000)) && !n.paidOnce, "a trial that never paid never counts")
    eq(n.cancelReason, "cancellation_requested", "cancellation reason read")
    eq(n.trialStart, t(1000), "trial start read")
    let legacy = StripeClient.fact(never, firstPaid: nil, now: now)!
    eq(legacy.invoicesRead, nil, "without invoices, the old rule")
    let deleted: [String: Any] = ["id": "sub_d", "status": "active", "customer": ["id": "cus_d", "deleted": true],
                                  "items": ["data": [["price": ["unit_amount": 1000, "currency": "eur", "recurring": ["interval": "month"]]]]]]
    check(StripeClient.fact(deleted, firstPaid: [:], now: now) == nil, "deleted customers count nowhere")
}

// MARK: projection over projects

do {
    var a = Account(name: "A"); a.id = UUID()
    let facts: [UUID: [SubFact]] = [a.id: [
        sub("active", customer: "x", monthly: 10000, paid: at(-40)),
        sub("active", customer: "h", monthly: 2000, trialStart: at(-60), trialEnd: at(-46), paid: at(-46)),
        sub("canceled", customer: "i", trialStart: at(-60), trialEnd: at(-46), canceledAt: at(-50), reason: "cancellation_requested", endedAt: at(-46)),
        sub("trialing", customer: "n", monthly: 3000, trialStart: at(0), trialEnd: at(14)),
        sub("trialing", customer: "o", monthly: 3000, trialStart: at(-12), trialEnd: at(2)),
        sub("past_due", customer: "p", monthly: 700, paid: at(-70)),
    ]]
    let p = Projection.build(accounts: [a], facts: facts, convert: { v, _ in v }, now: now)
    eq(p.real, 12000, "real MRR")
    eq(p.atRisk, 700, "at risk")
    // new trial: plain rate 1/2; 12 days old: the cancel at 10 days is out -> 1/1
    eq(p.expected, 1500 + 3000, "each trial at its own age")
    eq(p.projected, 12000 + 4500, "projection = real + expected")
    close(p.rate, 4500.0 / 6000.0, "displayed rate")
    eq(p.allAtHorizon, 12000 + 6000, "if every trial pays")
    let none = Projection.build(accounts: [a], facts: [a.id: [sub("active", paid: at(-3)), sub("trialing", trialStart: at(-1), trialEnd: at(13))]],
                                convert: { v, _ in v }, now: now)
    eq(none.projected, nil, "no projection until a trial has ended")
}

print(failures == 0 ? "ok: \(passed) checks" : "\(failures) failed, \(passed) passed")
exit(failures == 0 ? 0 : 1)
