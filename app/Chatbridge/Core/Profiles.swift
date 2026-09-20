import CryptoKit
import Foundation

/// A declarative description of how to read one app surface. Profiles ship
/// inside the signed app bundle, so they can't be swapped without breaking the
/// code signature; the checksum ties every stored record to the exact revision.
nonisolated struct Profile: @unchecked Sendable {
    let name: String
    let version: Int
    let data: [String: Any]
    let checksum: String

    var key: String { "\(name)@\(version)" }
    var appID: String { (data["app"] as? [String: Any])?["id"] as? String ?? name }
    var schema: String { data["schema"] as? String ?? "" }
    var hosts: [String] { (data["match"] as? [String: Any])?["hosts"] as? [String] ?? [] }
    var canary: [String: Any] { data["canary"] as? [String: Any] ?? [:] }
    var isDevelopmentFixture: Bool { appID.hasPrefix("dev.chatbridge.") }
}

nonisolated struct ProfileError: Error, CustomStringConvertible { let description: String }

nonisolated final class ProfileLibrary: @unchecked Sendable {
    static let shared = ProfileLibrary()

    let schemas: [String: [String: Any]]
    let profiles: [String: Profile]

    private init() {
        var schemas: [String: [String: Any]] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "schemas") ?? [] {
            if let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any], let name = doc["schema"] as? String {
                schemas[name] = doc
            }
        }
        var profiles: [String: Profile] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "profiles") ?? [] {
            guard let raw = try? Data(contentsOf: url),
                  let doc = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            do {
                try Self.validate(doc, schemas: schemas)
                let profile = Profile(
                    name: doc["profile"] as? String ?? "", version: doc["profileVersion"] as? Int ?? 0, data: doc,
                    checksum: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
                profiles[profile.key] = profile
            } catch {
                DebugLog.write("profiles: rejected \(url.lastPathComponent): \(error)")
            }
        }
        self.schemas = schemas
        self.profiles = profiles
        DebugLog.write("profiles: loaded \(profiles.keys.sorted().joined(separator: ", "))")
    }

    static func validate(_ data: [String: Any], schemas: [String: [String: Any]]) throws {
        for key in ["profile", "profileVersion", "app", "match", "schema", "canary"] where data[key] == nil {
            throw ProfileError(description: "missing key \(key)")
        }
        guard let schemaName = data["schema"] as? String, let schema = schemas[schemaName],
              let fields = schema["fields"] as? [String: [String: Any]] else { throw ProfileError(description: "unknown schema") }
        let method = data["method"] as? String ?? "dom"
        var produced: Set<String>
        switch method {
        case "dom":
            guard let extract = data["extract"] as? [String: Any], extract["item"] != nil,
                  let f = extract["fields"] as? [String: Any] else { throw ProfileError(description: "extract needs item and fields") }
            produced = Set(f.keys).union((extract["context"] as? [String: Any] ?? [:]).keys)
        case "page-store":
            guard let store = data["store"] as? [String: Any], let f = store["fields"] as? [String: Any],
                  (store["root"] as? String == "window" ? store["path"] : store["collection"]) != nil
            else { throw ProfileError(description: "store needs a source (collection, or window path) and fields") }
            produced = Set(f.keys)
        default:
            throw ProfileError(description: "unknown method \(method)")
        }
        let unknown = produced.subtracting(fields.keys)
        guard unknown.isEmpty else { throw ProfileError(description: "fields not in schema: \(unknown.sorted())") }
        let identity = fields.filter { $0.value["identity"] as? Bool == true }.map(\.key)
        guard Set(identity).isSubset(of: produced) else { throw ProfileError(description: "identity fields not extracted") }
        let checked = Set(((data["canary"] as? [String: Any])?["fillRate"] as? [String: Any] ?? [:]).keys)
        guard checked.isSubset(of: produced) else { throw ProfileError(description: "canary checks fields that are never extracted") }
    }

    /// Profiles a page on `host` may use. Development fixtures are never offered to real hosts.
    func profiles(forHost host: String, isQuarantined: (String) -> Bool) -> [[String: Any]] {
        profiles.values.filter { $0.hosts.contains(host) && !isQuarantined($0.key) }.map(\.data)
    }
}
