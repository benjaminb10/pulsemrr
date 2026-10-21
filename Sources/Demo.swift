// Made-up projects and numbers, for screenshots: `PulseMRR --demo-snapshot out.png`.
// Nothing is read from or written to disk and nothing is fetched from Stripe.
import AppKit
import SwiftUI

extension Model {
    static func demo() -> Model {
        let m = Model()
        m.persist = false
        let projects: [(String, String, NSColor, [Int], Int)] = [
            ("Pixel Forge", "P", NSColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1), [21900, 0, 4900, 9800, 14700, 4900, 19600], 412000),
            ("Tiny Courses", "T", NSColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1), [3900, 7800, 0, 11700, 3900, 0, 7800], 98000),
            ("Snapnote", "S", NSColor(red: 0.12, green: 0.70, blue: 0.62, alpha: 1), [0, 1200, 2400, 0, 1200, 3600, 2400], 46500),
            ("Heron Analytics", "H", NSColor(red: 0.18, green: 0.45, blue: 0.85, alpha: 1), [0, 0, 0, 0, 0, 0, 0], 120000),
        ]
        var accounts: [Account] = []
        for (name, letter, color, week, mrr) in projects {
            var a = Account(name: name, emoji: "💳", stripeID: "acct_demo\(accounts.count)", currency: "usd")
            a.useLogo = true
            accounts.append(a)
            m.logos[a.id] = letterIcon(letter, color)
            var days: [Date: [String: Int]] = [:]
            for (i, v) in week.reversed().enumerated() where v > 0 { days[m.day(i)] = ["usd": v] }
            // 23 more days of made-up but steady sales, so the sparklines have a shape
            var seed = UInt64(accounts.count + 7)
            for i in 7..<30 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let base = week.max() ?? 0
                let v = Int(Double(base) * (0.15 + Double(seed >> 40 & 0xFF) / 255.0 * 0.7) * (1.0 - Double(i) / 60.0))
                if v > 0 { days[m.day(i)] = ["usd": v / 100 * 100] }
            }
            m.daily[a.id] = days
            m.mrr[a.id] = ["usd": mrr]
            var d = MrrSnapshot()
            d.real = ["usd": mrr]; d.activeCount = mrr / 2900
            if accounts.count == 1 {
                d.failing = [FailingSub(id: "sub_demo1", who: "Max Mustermann", amount: 2900, currency: "usd", since: Date()),
                             FailingSub(id: "sub_demo2", who: "lea@example.com", amount: 2900, currency: "usd", since: Date())]
                d.atRisk = ["usd": 5800]; d.atRiskCount = 2; d.trials = ["usd": 23200]; d.trialCount = 8; d.trialsEnded = 40; d.trialsPaying = 15 }
            if accounts.count == 3 { d.trials = ["usd": 4800]; d.trialCount = 4; d.trialsEnded = 12; d.trialsPaying = 6 }
            if accounts.count == 2 { d.leaving = ["usd": 3900]; d.leavingCount = 1; d.trials = ["usd": 7800]; d.trialCount = 2; d.trialsEnded = 10; d.trialsPaying = 4 }
            m.mrrDetail[a.id] = d
            m.signups[a.id] = [m.day(0): [5, 2, 3, 0][accounts.count - 1], m.day(1): [4, 1, 2, 1][accounts.count - 1]]
            m.subscribers[a.id] = mrr / 2900
        }
        m.accounts = accounts
        var prefs = Prefs()
        prefs.displayCurrency = "usd"
        m.prefs = prefs
        m.rates = [:]
        let now = Date()
        func act(_ kind: EventKind, _ acc: Int, _ minutes: Double, _ amount: Int?, _ who: String?) -> Activity {
            Activity(id: UUID().uuidString, kind: kind, accountID: accounts[acc].id, created: now.addingTimeInterval(-minutes * 60),
                     amount: amount, currency: amount == nil ? nil : "usd", who: who, customerID: nil, objectID: "ch_demo", live: true)
        }
        m.recent = [
            act(.sale, 0, 3, 4900, "Ada Lovelace (ada@example.com)"),
            act(.newSubscriber, 1, 18, 3900, "sam@example.com"),
            act(.trialConverted, 0, 52, 9800, "Grace H."),
            act(.sale, 2, 95, 1200, "Linus T."),
            act(.canceled, 1, 140, 3900, "jo@example.com"),
            act(.payout, 0, 300, 152000, nil),
            act(.paymentFailed, 2, 420, 1200, "max@example.com"),
        ]
        m.lastPoll = now.addingTimeInterval(-4)
        demoHistory(m, accounts, prices: [[2900, 4900, 9900], [3900], [1200, 2400], [4900, 19900]],
                    signupsPerWeek: [7, 3, 4, 1.4], churn: [0.035, 0.06, 0.05, 0.02], trials: [true, false, true, false])
        return m
    }

    /// 18 months of made-up subscribers per project, growing, paying and leaving, with their payments and failed invoices.
    private static func demoHistory(_ m: Model, _ accounts: [Account], prices: [[Int]], signupsPerWeek: [Double], churn: [Double], trials: [Bool]) {
        var seed: UInt64 = 42
        func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let day: TimeInterval = 86400
        let now = Date()
        let names = ["Ada", "Grace", "Linus", "Margaret", "Alan", "Hedy", "Dennis", "Barbara", "Ken", "Frances", "Tim", "Radia",
                     "Guido", "Anita", "Brendan", "Katherine", "Bjarne", "Sophie", "Yukihiro", "Lynn"]
        let last = ["Lovelace", "Hopper", "Torvalds", "Hamilton", "Turing", "Lamarr", "Ritchie", "Liskov", "Thompson", "Allen",
                    "Berners-Lee", "Perlman", "van Rossum", "Borg", "Eich", "Johnson", "Stroustrup", "Wilson", "Matsumoto", "Conway"]
        for (ai, a) in accounts.enumerated() {
            var facts: [SubFact] = []
            var revenue: [Date: [String: Int]] = [:]
            var failed: [FailedInvoice] = []
            for week in 0..<78 {
                // Sign-ups grow over time, from a third of today's pace 18 months ago
                let rate = signupsPerWeek[ai] * (0.35 + 0.65 * Double(week) / 78)
                var n = Int(rate); if rand() < rate - Double(n) { n += 1 }
                for _ in 0..<n {
                    let created = now.addingTimeInterval(-Double(78 - week) * 7 * day + rand() * 7 * day)
                    let price = prices[ai][Int(rand() * Double(prices[ai].count))]
                    let trialEnd: Date? = trials[ai] ? created.addingTimeInterval(14 * day) : nil
                    if trials[ai] && rand() > 0.42 {
                        // Trial that never paid
                        facts.append(SubFact(id: "sub_\(facts.count)", customer: "cus_\(ai)_\(facts.count)", who: nil, currency: "usd", monthly: price,
                                             start: trialEnd!, end: trialEnd, trialEnd: trialEnd, status: trialEnd! > now ? "trialing" : "canceled",
                                             created: created, canceledAt: created.addingTimeInterval(rand() * 13 * day), cancelAt: trialEnd))
                        continue
                    }
                    let start = trialEnd ?? created
                    guard start < now else {
                        facts.append(SubFact(id: "sub_\(facts.count)", customer: "cus_\(ai)_\(facts.count)", who: nil, currency: "usd", monthly: price,
                                             start: start, end: nil, trialEnd: trialEnd, status: "trialing", created: created))
                        continue
                    }
                    // Months paid before leaving, from the monthly churn rate
                    var months = 1
                    while rand() > churn[ai] && months < 40 { months += 1 }
                    let endAt = Calendar.current.date(byAdding: .month, value: months, to: start)!
                    let end: Date? = endAt < now ? endAt : nil
                    let who = names[Int(rand() * 20)] + " " + last[Int(rand() * 20)]
                    facts.append(SubFact(id: "sub_\(facts.count)", customer: "cus_\(ai)_\(facts.count)", who: who, currency: "usd", monthly: price,
                                         start: start, end: end, trialEnd: trialEnd, status: end == nil ? "active" : "canceled", created: created))
                    var t = start
                    while t < (end ?? now) {
                        let d = Calendar.current.startOfDay(for: t)
                        revenue[d, default: [:]]["usd", default: 0] += price
                        if t > now.addingTimeInterval(-90 * day), rand() < 0.03 {
                            let state: FailedInvoice.State = rand() < 0.6 ? .recovered : (rand() < 0.5 ? .lost : .retrying)
                            failed.append(FailedInvoice(id: "in_demo\(failed.count)\(ai)", who: who, amount: price, currency: "usd", created: t, state: state, live: true))
                        }
                        t = Calendar.current.date(byAdding: .month, value: 1, to: t)!
                    }
                }
            }
            m.facts[a.id] = facts
            m.revenue[a.id] = revenue
            m.failedInvoices[a.id] = failed
            // The panel shows the same MRR as the dashboard
            let mrr = facts.filter { $0.pays(at: now) }.reduce(0) { $0 + $1.monthly }
            m.mrr[a.id] = ["usd": mrr]
            m.mrrDetail[a.id]?.real = ["usd": mrr]
        }
        m.prefs.goal = 25000
        m.dashboardUpdated = now
    }

    private static func letterIcon(_ letter: String, _ color: NSColor) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.white]
        let s = letter as NSString
        let b = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}

/// True while drawing an image: scroll views and borderless buttons don't render off screen, so plain views stand in.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
