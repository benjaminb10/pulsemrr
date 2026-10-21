// Made-up projects and numbers, for screenshots: `Kaching --demo-snapshot out.png`.
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
            m.daily[a.id] = days
            m.mrr[a.id] = ["usd": mrr]
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
        return m
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
