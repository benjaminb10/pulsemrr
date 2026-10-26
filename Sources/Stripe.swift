// Read-only calls to the Stripe API: events (what to notify), today's charges and active subscriptions (MRR).
// Every call is a GET: the app never changes anything in Stripe.
import Foundation

struct StripeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct StripeClient {
    let key: String
    let connectedAccount: String?

    func get(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://api.stripe.com/v1/" + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let acct = connectedAccount, !acct.isEmpty { req.setValue(acct, forHTTPHeaderField: "Stripe-Account") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw StripeError(message: msg)
        }
        return json
    }

    /// Every page of a list endpoint, up to `max` objects.
    func list(_ path: String, _ query: [(String, String)], max: Int = 1000) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var after: String?
        repeat {
            var q = query + [("limit", "100")]
            if let after { q.append(("starting_after", after)) }
            let page = try await get(path, q)
            let items = page["data"] as? [[String: Any]] ?? []
            all += items
            after = (page["has_more"] as? Bool == true) ? items.last?["id"] as? String : nil
        } while after != nil && all.count < max
        return all
    }

    struct AccountInfo {
        let id: String, name: String, currency: String, live: Bool
        /// The icon set in Stripe (Settings › Branding), as a file id, and the business website.
        let iconFile: String?, website: String?
    }

    /// Who this key belongs to: the account's display name, currency, branding icon and website.
    func account() async throws -> AccountInfo {
        let a = try await get(connectedAccount.map { "accounts/\($0)" } ?? "account")
        let settings = a["settings"] as? [String: Any]
        let profile = a["business_profile"] as? [String: Any]
        let name = (settings?["dashboard"] as? [String: Any])?["display_name"] as? String
            ?? profile?["name"] as? String ?? a["id"] as? String ?? "Stripe"
        let branding = settings?["branding"] as? [String: Any]
        let icon = (branding?["icon"] as? String) ?? (branding?["logo"] as? String)
        return AccountInfo(id: a["id"] as? String ?? "", name: name, currency: a["default_currency"] as? String ?? "eur",
                           live: key.contains("_live_"), iconFile: icon, website: profile?["url"] as? String)
    }

    /// The bytes of a Stripe file, such as the branding icon.
    func fileContents(_ id: String) async -> Data? {
        var req = URLRequest(url: URL(string: "https://files.stripe.com/v1/files/\(id)/contents")!, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let acct = connectedAccount, !acct.isEmpty { req.setValue(acct, forHTTPHeaderField: "Stripe-Account") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    func events(since: Int) async throws -> [[String: Any]] {
        let types = EventKind.allCases.flatMap(\.stripeTypes)
        var q: [(String, String)] = [("created[gt]", String(since))]
        q += types.map { ("types[]", $0) }
        return try await list("events", q, max: 300)
    }

    func customerLabel(_ id: String) async -> String? {
        guard let c = try? await get("customers/\(id)") else { return nil }
        return Self.person(name: c["name"] as? String, email: c["email"] as? String)
    }

    static func person(name: String?, email: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespaces), e = email?.trimmingCharacters(in: .whitespaces)
        switch (n?.isEmpty == false ? n : nil, e?.isEmpty == false ? e : nil) {
        case let (n?, _?): return n
        case let (n?, nil): return n
        case let (nil, e?): return e
        default: return nil
        }
    }

    /// Money taken per local day over the last `days` days (today included), per currency, refunds taken off.
    func daily(days: Int, max: Int = 10000) async throws -> [Date: [String: Int]] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        let charges = try await list("charges", [("created[gte]", String(Int(start.timeIntervalSince1970)))], max: max)
        var out: [Date: [String: Int]] = [:]
        for c in charges where (c["paid"] as? Bool) == true && (c["status"] as? String) == "succeeded" {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(c["created"] as? Int ?? 0)))
            let cur = c["currency"] as? String ?? "eur"
            out[day, default: [:]][cur, default: 0] += (c["amount"] as? Int ?? 0) - (c["amount_refunded"] as? Int ?? 0)
        }
        return out
    }

    /// New Stripe customers per local day over the last `days` days (trials included: anyone who reached checkout).
    func newCustomers(days: Int) async throws -> [Date: Int] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        let customers = try await list("customers", [("created[gte]", String(Int(start.timeIntervalSince1970)))], max: 10000)
        var out: [Date: Int] = [:]
        for c in customers {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(c["created"] as? Int ?? 0)))
            out[day, default: 0] += 1
        }
        return out
    }

    /// MRR the way a founder reads it, not Stripe's headline figure (the rules are in Metrics.swift):
    /// real = active subscriptions only; at risk = past_due; trials = trialing and not set to cancel;
    /// projected = real + each trial x the pay rate of ended trials at its age. Deleted customers never count.
    func mrr() async throws -> MrrSnapshot { try await mrrAndHistory().0 }

    /// The MRR snapshot and every subscription as a fact, from one read of the list. `firstPaid`: each subscription's
    /// first paid invoice (nil when the invoices can't be read). `excluded`: emails left out everywhere (lowercase).
    func mrrAndHistory(firstPaid: [String: Date]? = nil, excluded: Set<String> = []) async throws -> (MrrSnapshot, [SubFact]) {
        let subs = try await list("subscriptions", [("status", "all"), ("expand[]", "data.customer"), ("expand[]", "data.latest_invoice")], max: 20000)
        let now = Date()
        let facts = subs.compactMap { StripeClient.fact($0, firstPaid: firstPaid, now: now) }.filter { !excluded.contains($0.email ?? "") }
        return (MrrSnapshot.from(facts, now: now), facts)
    }

    /// One subscription's monthly equivalent at list price (yearly / 12, weekly x 52 / 12), per currency.
    static func monthlyValue(_ s: [String: Any]) -> [String: Int] {
        var sums: [String: Int] = [:]
        let items = (s["items"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        for item in items {
            guard let price = item["price"] as? [String: Any], let recurring = price["recurring"] as? [String: Any],
                  let amount = price["unit_amount"] as? Int else { continue }
            let qty = item["quantity"] as? Int ?? 1
            let count = Double(recurring["interval_count"] as? Int ?? 1)
            let perMonth: Double
            switch recurring["interval"] as? String {
            case "day": perMonth = 30.4375 / count
            case "week": perMonth = 52.0 / 12.0 / count
            case "year": perMonth = 1.0 / 12.0 / count
            default: perMonth = 1.0 / count
            }
            let cur = price["currency"] as? String ?? (s["currency"] as? String ?? "eur")
            sums[cur, default: 0] += Int((Double(amount * qty) * perMonth).rounded())
        }
        return sums
    }
}

/// A subscription whose payment failed: something to chase.
struct FailingSub: Codable, Identifiable, Hashable {
    let id: String
    let who: String?
    let amount: Int
    let currency: String
    let since: Date
}

struct MrrSnapshot: Codable {
    var failing: [FailingSub] = []
    var real: [String: Int] = [:]
    var activeCount = 0
    var leaving: [String: Int] = [:]
    var leavingCount = 0
    var atRisk: [String: Int] = [:]
    var atRiskCount = 0
    var trials: [String: Int] = [:]
    var trialCount = 0
    var trialsCancelling = 0
    var trialsEnded = 0
    var trialsPaying = 0
    var trialsFailed = 0
    var trialsCancelled = 0
    /// What the running trials should bring: each one x the pay rate of ended trials at its age, per currency.
    var expected: [String: Int] = [:]
    /// Churn over the last 30 days: paying customers lost, out of the ones who paid during the window.
    var churnBase = 0
    var churnLost = 0
    var churnCancelled = 0
    var churnFailed = 0
    var churnLostMrr: [String: Int] = [:]
    /// Customers who ever paid, and how many of them no longer do.
    var everPaid = 0
    var lostAllTime = 0

    /// The share of the running trials' MRR expected to pay (0...1), nil until a trial has ended.
    var conversion: Double? {
        let t = trials.values.reduce(0, +)
        return trialsEnded > 0 && t > 0 ? Double(expected.values.reduce(0, +)) / Double(t) : nil
    }
    var churnRate: Double? { churnBase > 0 ? Double(churnLost) / Double(churnBase) : nil }
}

/// The kinds of things worth a notification, each switchable in the settings.
enum EventKind: String, CaseIterable, Codable, Identifiable {
    case sale, newSubscriber, trialStarted, trialConverted, canceled, ended, paymentFailed, refund, dispute, newCustomer, payout
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sale: return String(localized: "New sale")
        case .newSubscriber: return String(localized: "New subscriber")
        case .trialStarted: return String(localized: "New trial")
        case .trialConverted: return String(localized: "Trial converted")
        case .canceled: return String(localized: "Cancellation scheduled")
        case .ended: return String(localized: "Subscription ended")
        case .paymentFailed: return String(localized: "Payment failed")
        case .refund: return String(localized: "Refund")
        case .dispute: return String(localized: "Dispute")
        case .newCustomer: return String(localized: "New customer")
        case .payout: return String(localized: "Payout received")
        }
    }

    var emoji: String {
        switch self {
        case .sale: return "💰"
        case .newSubscriber: return "🎉"
        case .trialStarted: return "🧪"
        case .trialConverted: return "✅"
        case .canceled: return "👋"
        case .ended: return "🛑"
        case .paymentFailed: return "⚠️"
        case .refund: return "↩️"
        case .dispute: return "🚨"
        case .newCustomer: return "👤"
        case .payout: return "🏦"
        }
    }

    /// Everything is on by default. A new customer who starts a trial or pays in the same minute gets one notification, not two.
    var defaultOn: Bool { true }

    var stripeTypes: [String] {
        switch self {
        case .sale: return ["charge.succeeded"]
        case .newSubscriber, .trialStarted: return ["customer.subscription.created"]
        case .trialConverted, .canceled: return ["customer.subscription.updated"]
        case .ended: return ["customer.subscription.deleted"]
        case .paymentFailed: return ["invoice.payment_failed"]
        case .refund: return ["charge.refunded"]
        case .dispute: return ["charge.dispute.created"]
        case .newCustomer: return ["customer.created"]
        case .payout: return ["payout.paid"]
        }
    }
}

/// One Stripe event, read into what the app shows.
struct Activity: Identifiable, Codable, Hashable {
    /// The same event told as another kind (a payment that is in fact a trial's conversion).
    func with(kind: EventKind) -> Activity {
        Activity(id: id, kind: kind, accountID: accountID, created: created, amount: amount, currency: currency,
                 who: who, customerID: customerID, objectID: objectID, live: live)
    }

    let id: String
    let kind: EventKind
    let accountID: UUID
    let created: Date
    let amount: Int?
    let currency: String?
    var who: String?
    let customerID: String?
    let objectID: String
    let live: Bool

    var dashboardURL: URL {
        // A trial's conversion is shown at its first payment: open the payment
        if objectID.hasPrefix("ch_") || objectID.hasPrefix("py_") {
            return URL(string: (live ? "https://dashboard.stripe.com/" : "https://dashboard.stripe.com/test/") + "payments/\(objectID)")!
        }
        if objectID.hasPrefix("rc:") { return URL(string: "https://app.revenuecat.com/projects/\(objectID.dropFirst(3))/overview")! }
        let base = live ? "https://dashboard.stripe.com/" : "https://dashboard.stripe.com/test/"
        let path: String
        switch kind {
        case .sale, .refund: path = "payments/\(objectID)"
        case .dispute: path = "disputes/\(objectID)"
        case .paymentFailed: path = "invoices/\(objectID)"
        case .payout: path = "payouts/\(objectID)"
        case .newCustomer: path = "customers/\(objectID)"
        default: path = "subscriptions/\(objectID)"
        }
        return URL(string: base + path)!
    }

    /// Reads a raw Stripe event. Nil when the event isn't one we notify about (say, an ordinary subscription update).
    static func from(_ e: [String: Any], account: UUID) -> Activity? {
        guard let type = e["type"] as? String, let id = e["id"] as? String,
              let data = e["data"] as? [String: Any], let o = data["object"] as? [String: Any] else { return nil }
        let prev = data["previous_attributes"] as? [String: Any] ?? [:]
        let created = Date(timeIntervalSince1970: TimeInterval(e["created"] as? Int ?? 0))
        let live = e["livemode"] as? Bool ?? true
        let objectID = o["id"] as? String ?? ""
        let customer = o["customer"] as? String
        func make(_ kind: EventKind, _ amount: Int?, _ currency: String?, _ who: String?) -> Activity {
            Activity(id: id, kind: kind, accountID: account, created: created, amount: amount, currency: currency,
                     who: who, customerID: customer, objectID: objectID, live: live)
        }
        func subAmount() -> (Int?, String?) {
            let items = (o["items"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            guard let price = items.first?["price"] as? [String: Any] else { return (nil, nil) }
            let qty = items.first?["quantity"] as? Int ?? 1
            return ((price["unit_amount"] as? Int).map { $0 * qty }, price["currency"] as? String)
        }
        switch type {
        case "charge.succeeded":
            let billing = o["billing_details"] as? [String: Any]
            let who = StripeClient.person(name: billing?["name"] as? String,
                                          email: (billing?["email"] as? String) ?? (o["receipt_email"] as? String))
            return make(.sale, o["amount"] as? Int, o["currency"] as? String, who)
        case "charge.refunded":
            return make(.refund, o["amount_refunded"] as? Int, o["currency"] as? String,
                        StripeClient.person(name: (o["billing_details"] as? [String: Any])?["name"] as? String,
                                            email: (o["billing_details"] as? [String: Any])?["email"] as? String))
        case "charge.dispute.created":
            return make(.dispute, o["amount"] as? Int, o["currency"] as? String, nil)
        case "customer.subscription.created":
            let (a, c) = subAmount()
            return make((o["status"] as? String) == "trialing" ? .trialStarted : .newSubscriber, a, c, nil)
        case "customer.subscription.updated":
            let (a, c) = subAmount()
            if (prev["status"] as? String) == "trialing", (o["status"] as? String) == "active" { return make(.trialConverted, a, c, nil) }
            if prev["cancel_at_period_end"] as? Bool == false, o["cancel_at_period_end"] as? Bool == true { return make(.canceled, a, c, nil) }
            return nil
        case "customer.subscription.deleted":
            let (a, c) = subAmount()
            return make(.ended, a, c, nil)
        case "invoice.payment_failed":
            return make(.paymentFailed, o["amount_due"] as? Int, o["currency"] as? String,
                        StripeClient.person(name: o["customer_name"] as? String, email: o["customer_email"] as? String))
        case "customer.created":
            return Activity(id: id, kind: .newCustomer, accountID: account, created: created, amount: nil, currency: nil,
                            who: StripeClient.person(name: o["name"] as? String, email: o["email"] as? String),
                            customerID: objectID, objectID: objectID, live: live)
        case "payout.paid":
            return make(.payout, o["amount"] as? Int, o["currency"] as? String, nil)
        default:
            return nil
        }
    }
}

enum Money {
    /// Locale for numbers and dates (the Mac's, or English for the README screenshots).
    static var locale = Locale.current

    /// `whole`: no cents under a thousand ("142 €"), for lists of figures to compare at a glance.
    static func format(_ minor: Int, _ currency: String, compact: Bool = false, whole: Bool = false) -> String {
        let code = currency.uppercased()
        let zeroDecimal: Set = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
        let value = Double(minor) / (zeroDecimal.contains(code) ? 1 : 100)
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Money.locale
        if compact && abs(value) >= 1000 {
            // "2,8 k€", "1,2 k$US": the number in thousands, then k and the currency symbol
            let n = NumberFormatter()
            n.numberStyle = .decimal
            n.locale = f.locale
            n.maximumFractionDigits = 1
            let s = n.string(from: NSNumber(value: value / 1000)) ?? "\(value / 1000)"
            let symbol = f.currencySymbol ?? code
            // Where the locale puts the symbol: "$4.1k" in English, "4,1 k€" in French
            let symbolFirst = (f.string(from: 1) ?? "").hasPrefix(symbol)
            return symbolFirst ? symbol + s + "k" : s + "\u{202F}k" + symbol
        }
        if whole { f.maximumFractionDigits = 0 } else if compact { f.maximumFractionDigits = value.rounded() == value ? 0 : 2 }
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }

    static func format(_ sums: [String: Int], compact: Bool = false) -> String {
        if sums.isEmpty { return format(0, "eur", compact: compact) }
        return sums.sorted { $0.value > $1.value }.map { format($0.value, $0.key, compact: compact) }.joined(separator: " + ")
    }
}
