// RevenueCat, for the mobile apps: a secret API v2 key per project, read-only. RevenueCat has no event feed to poll,
// so PulseMRR reads its charts (revenue and new customers per day) and its overview (MRR, subscriptions, trials),
// and notifies a sale when today's revenue goes up between two reads.
import Foundation

struct RevenueCatClient {
    let key: String
    private let base = URL(string: "https://api.revenuecat.com/v2/")!

    struct ProjectInfo { let id: String; let name: String; let icon: URL? }

    struct RCError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw RCError(message: json["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return json
    }

    /// The projects this key reads: a secret key belongs to one project.
    func projects() async throws -> [ProjectInfo] {
        let j = try await get("projects")
        return (j["items"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return ProjectInfo(id: id, name: p["name"] as? String ?? id,
                               icon: (p["icon_url_large"] as? String ?? p["icon_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// The overview's figures by id (mrr, revenue, active_subscriptions, active_trials, new_customers, …), money in major units.
    func overview(_ project: String, currency: String) async throws -> [String: Double] {
        let j = try await get("projects/\(project)/metrics/overview", ["currency": currency.uppercased()])
        var out: [String: Double] = [:]
        for m in j["metrics"] as? [[String: Any]] ?? [] {
            if let id = m["id"] as? String, let v = (m["value"] as? NSNumber)?.doubleValue { out[id] = v }
        }
        return out
    }

    /// One chart, one value per day (local midnight), over the last `days` days.
    func daily(_ chart: String, _ project: String, days: Int, currency: String) async throws -> [Date: Double] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let end = Date(), start = cal.date(byAdding: .day, value: -(days - 1), to: end)!
        let j = try await get("projects/\(project)/charts/\(chart)", [
            "resolution": "0", "start_date": f.string(from: start), "end_date": f.string(from: end), "currency": currency.uppercased(),
        ])
        var out: [Date: Double] = [:]
        for row in j["values"] as? [Any] ?? [] {
            // A row is [time, value, …] or {cohort, value}; the time is in seconds or milliseconds since 1970
            var t: Double?, v: Double?
            if let a = row as? [Any] {
                t = (a.first as? NSNumber)?.doubleValue
                v = a.count > 1 ? (a[1] as? NSNumber)?.doubleValue : nil
            } else if let o = row as? [String: Any] {
                // Rows come for each measure (revenue, transactions, …): the first one is the chart's own
                if let m = (o["measure"] as? NSNumber)?.intValue, m != 0 { continue }
                t = (o["cohort"] as? NSNumber)?.doubleValue
                v = (o["value"] as? NSNumber)?.doubleValue
            }
            guard var time = t, let value = v else { continue }
            if time > 10_000_000_000 { time /= 1000 }
            // The chart's days are UTC dates: keep the date, at local midnight
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: time))
            guard let day = cal.date(from: parts) else { continue }
            out[day, default: 0] += value
        }
        return out
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let v = self else { return nil }
        return await f(v)
    }
}
