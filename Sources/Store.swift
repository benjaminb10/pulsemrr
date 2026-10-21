// What the app remembers: the Stripe accounts (keys in the Keychain, never in a file), the settings,
// and where each account's polling left off.
import Foundation
import Security

struct Account: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String = "💳"
    /// For a Connect platform key that reads one of its connected accounts (Stripe-Account header). Usually empty.
    var connectedAccount: String = ""
    var stripeID: String = ""
    var currency: String = "eur"
    var live: Bool = true
    var enabled: Bool = true
    /// Show the project's logo (from Stripe branding, or the website's favicon) instead of the emoji.
    var useLogo: Bool = true
    var website: String = ""

    enum CodingKeys: String, CodingKey { case id, name, emoji, connectedAccount, stripeID, currency, live, enabled, useLogo, website }
    init(name: String, emoji: String = "💳", connectedAccount: String = "", stripeID: String = "", currency: String = "eur", live: Bool = true) {
        self.name = name; self.emoji = emoji; self.connectedAccount = connectedAccount
        self.stripeID = stripeID; self.currency = currency; self.live = live
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "💳"
        connectedAccount = try c.decodeIfPresent(String.self, forKey: .connectedAccount) ?? ""
        stripeID = try c.decodeIfPresent(String.self, forKey: .stripeID) ?? ""
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "eur"
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        useLogo = try c.decodeIfPresent(Bool.self, forKey: .useLogo) ?? true
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
    }

    var logoURL: URL { Disk.folder.appendingPathComponent("logos/\(id.uuidString).png") }
}

enum Keychain {
    static let service = "app.pulsemrr.stripe"

    static func save(_ key: String, for id: UUID) {
        delete(id)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(_ id: UUID) -> String? { read(id, service) }

    private static func read(_ id: UUID, _ service: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ id: UUID) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

struct Prefs: Codable, Equatable {
    var kinds: Set<EventKind> = Set(EventKind.allCases.filter(\.defaultOn))
    var sound = true
    var showAmountInMenuBar = true
    var pollSeconds = 30
    var displayCurrency = "eur"
    var recapEnabled = true
    var showSignupsInMenuBar = true
    var recapHour = 20
    /// MRR goal for the dashboard, whole units of the display currency. 0: none.
    var goal = 0

    enum CodingKeys: String, CodingKey { case kinds, sound, showAmountInMenuBar, pollSeconds, displayCurrency, recapEnabled, recapHour, showSignupsInMenuBar, goal }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kinds = try c.decodeIfPresent(Set<EventKind>.self, forKey: .kinds) ?? kinds
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
        showAmountInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showAmountInMenuBar) ?? showAmountInMenuBar
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? pollSeconds
        displayCurrency = try c.decodeIfPresent(String.self, forKey: .displayCurrency) ?? displayCurrency
        recapEnabled = try c.decodeIfPresent(Bool.self, forKey: .recapEnabled) ?? recapEnabled
        recapHour = try c.decodeIfPresent(Int.self, forKey: .recapHour) ?? recapHour
        showSignupsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showSignupsInMenuBar) ?? showSignupsInMenuBar
        goal = try c.decodeIfPresent(Int.self, forKey: .goal) ?? goal
    }
}

/// Small JSON files in ~/Library/Application Support/PulseMRR. Nothing secret goes there.
enum Disk {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PulseMRR", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(value).write(to: url, options: .atomic)
    }
}

/// Where polling left off for one account: the newest event time seen, and the ids already shown at that second.
struct Cursor: Codable {
    var since: Int
    var seen: [String] = []
}
