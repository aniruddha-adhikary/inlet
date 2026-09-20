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

    func app(_ id: String) -> AppDescriptor? { apps.first { $0.id == id } }

    func name(_ id: String) -> String {
        if let app = app(id) { return app.name }
        return id.hasPrefix("dev.inlet.") ? "Demo" : id
    }
}

/// What the user chose for each app. Holds no content, so plain preferences are enough.
nonisolated enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var added: [String] {
        get { defaults.stringArray(forKey: "apps.added") ?? [] }
        set { defaults.set(newValue, forKey: "apps.added") }
    }

    /// Paused apps stay signed in but are not read, and nothing from them is offered to Siri.
    static func isPaused(_ id: String) -> Bool { defaults.bool(forKey: "app.\(id).paused") }
    static func setPaused(_ id: String, _ paused: Bool) { defaults.set(paused, forKey: "app.\(id).paused") }
    static var paused: Set<String> { Set(added.filter(isPaused)) }

    /// 0 keeps everything. Otherwise items older than this many days are deleted and ignored.
    static func keepDays(_ id: String) -> Int { defaults.integer(forKey: "app.\(id).keepDays") }
    static func setKeepDays(_ id: String, _ days: Int) { defaults.set(days, forKey: "app.\(id).keepDays") }

    static func cutoff(_ id: String) -> Date? {
        let days = keepDays(id)
        return days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
    }

    static func forget(_ id: String) {
        added.removeAll { $0 == id }
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

    /// People who connected an app before the app list existed keep their apps.
    static func migrate(catalog: AppCatalog) {
        guard defaults.object(forKey: "apps.added") == nil else { return }
        added = catalog.apps.filter { defaults.bool(forKey: "source.connected.\($0.id)") }.map(\.id)
        if !added.isEmpty { hasSeenWelcome = true }
    }
}

extension Color {
    nonisolated init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8E8E93
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
