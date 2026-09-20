import Foundation
import SwiftUI

/// One app Inlet knows how to read. Descriptors ship as JSON inside the signed
/// bundle (`apps/*.json`), so supporting a new app means adding files, not code.
nonisolated struct AppDescriptor: Identifiable, Sendable, Equatable {
    /// What an app contributes. Only messages exist today; the catalog and the
    /// interface are written so other kinds slot in.
    enum Kind: String, Sendable {
        case messages, notes, tasks, documents

        var itemNoun: String {
            switch self {
            case .messages: "Messages"
            case .notes: "Notes"
            case .tasks: "Tasks"
            case .documents: "Documents"
            }
        }

        /// The thing a user hides from Siri inside an app of this kind.
        var containerNoun: String { self == .messages ? "Chats" : "Items" }
    }

    let id: String              // app id used by the profiles, e.g. net.whatsapp.web
    let name: String
    let kind: Kind
    let isAvailable: Bool       // false: listed in the gallery as coming later
    let symbol: String
    let tintHex: String
    let url: URL?
    /// Hosts the main frame may navigate to. Anything else opens in the default browser.
    let allowedHosts: Set<String>
    /// JS evaluated in the page; returns "connected", "login" or "loading". Reads structure only.
    let loginProbe: String
    let needsStorePage: Bool    // inject the in-page store reader (page world)

    var tint: Color { Color(hex: tintHex) }
}

nonisolated final class AppCatalog: Sendable {
    static let shared = AppCatalog()

    let apps: [AppDescriptor]

    private init() {
        var apps: [AppDescriptor] = []
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "apps") ?? [] {
            guard let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
                  let id = doc["id"] as? String, let name = doc["name"] as? String else {
                DebugLog.write("catalog: rejected \(url.lastPathComponent)")
                continue
            }
            let site = (doc["url"] as? String).flatMap(URL.init(string:))
            let hosts = Set(doc["allowedHosts"] as? [String] ?? [])
            // An app can only be offered if it says where to sign in and which hosts it is confined to.
            let available = doc["status"] as? String == "available" && site?.scheme == "https" && !hosts.isEmpty
            apps.append(AppDescriptor(
                id: id, name: name, kind: AppDescriptor.Kind(rawValue: doc["kind"] as? String ?? "") ?? .messages,
                isAvailable: available, symbol: doc["symbol"] as? String ?? "app.fill",
                tintHex: doc["tint"] as? String ?? "#8E8E93", url: site, allowedHosts: hosts,
                loginProbe: doc["loginProbe"] as? String ?? "'loading'", needsStorePage: doc["needsStorePage"] as? Bool ?? false))
        }
        self.apps = apps.sorted { ($0.isAvailable ? 0 : 1, $0.name) < ($1.isAvailable ? 0 : 1, $1.name) }
    }

    /// Accepts an app id or an account key.
    func app(_ key: String) -> AppDescriptor? {
        let id = Account.appID(ofKey: key)
        return apps.first { $0.id == id }
    }

    /// What Siri and the interface call the place an item came from: "WhatsApp", or "WhatsApp Work".
    func name(_ key: String) -> String {
        guard let app = app(key) else { return key.hasPrefix("dev.inlet.") ? "Demo" : key }
        guard let account = AppSettings.accounts.first(where: { $0.key == key }) else { return app.name }
        let name = account.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == app.name { return app.name }
        return name.localizedCaseInsensitiveContains(app.name) ? name : "\(app.name) \(name)"
    }
}

/// One sign-in to an app. People can have as many as they like ("WhatsApp Work", "WhatsApp Home"),
/// each with its own isolated web session, its own stored items and its own settings.
nonisolated struct Account: Codable, Identifiable, Sendable, Equatable {
    /// Scopes everything the account contributes: `<appID>` for the first-ever account of an app
    /// (what earlier versions stored), `<appID>#<suffix>` for every account added since.
    let key: String
    var name: String
    /// The account's private website data store. nil: the app-wide default store (accounts from before 0.5).
    let storeID: UUID?

    var id: String { key }
    var appID: String { Self.appID(ofKey: key) }

    static func appID(ofKey key: String) -> String {
        key.firstIndex(of: "#").map { String(key[..<$0]) } ?? key
    }

    static func new(for app: AppDescriptor, among existing: [Account]) -> Account {
        let store = UUID()
        let siblings = existing.filter { $0.appID == app.id }.count
        return Account(key: "\(app.id)#\(store.uuidString.prefix(8).lowercased())",
                       name: siblings == 0 ? app.name : "\(app.name) \(siblings + 1)", storeID: store)
    }
}

/// What the user chose for each app. Holds no content, so plain preferences are enough.
nonisolated enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var accounts: [Account] {
        get { defaults.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "accounts") }
    }

    /// Paused apps stay signed in but are not read, and nothing from them is offered to Siri.
    static func isPaused(_ id: String) -> Bool { defaults.bool(forKey: "app.\(id).paused") }
    static func setPaused(_ id: String, _ paused: Bool) { defaults.set(paused, forKey: "app.\(id).paused") }
    static var paused: Set<String> { Set(accounts.map(\.key).filter(isPaused)) }

    /// 0 keeps everything. Otherwise items older than this many days are deleted and ignored.
    static func keepDays(_ id: String) -> Int { defaults.integer(forKey: "app.\(id).keepDays") }
    static func setKeepDays(_ id: String, _ days: Int) { defaults.set(days, forKey: "app.\(id).keepDays") }

    static func cutoff(_ id: String) -> Date? {
        let days = keepDays(id)
        return days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
    }

    static func forget(_ id: String) {
        accounts.removeAll { $0.key == id }
        for key in ["paused", "keepDays"] { defaults.removeObject(forKey: "app.\(id).\(key)") }
        defaults.removeObject(forKey: "source.connected.\(id)")
    }

    static var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: "welcome.seen") }
        set { defaults.set(newValue, forKey: "welcome.seen") }
    }

    static var hasSeenTour: Bool {
        get { defaults.bool(forKey: "tour.seen") }
        set { defaults.set(newValue, forKey: "tour.seen") }
    }

    static var hidesMenuBarIcon: Bool {
        get { defaults.bool(forKey: "settings.hideMenuBarIcon") }
        set { defaults.set(newValue, forKey: "settings.hideMenuBarIcon") }
    }

    /// Earlier versions knew one sign-in per app. Those become accounts that keep their key, so
    /// everything already stored and indexed still belongs to them.
    static func migrate(catalog: AppCatalog) {
        guard defaults.object(forKey: "accounts") == nil else { return }
        let legacy = defaults.stringArray(forKey: "apps.added")
            ?? catalog.apps.filter { defaults.bool(forKey: "source.connected.\($0.id)") }.map(\.id)
        accounts = legacy.compactMap { catalog.app($0) }.map { Account(key: $0.id, name: $0.name, storeID: nil) }
        if !accounts.isEmpty { hasSeenWelcome = true }
    }
}

extension Color {
    nonisolated init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8E8E93
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
