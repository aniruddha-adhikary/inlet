import CryptoKit
import Foundation

/// Identity, normalization, the canary check and the ingest transaction:
/// the Swift port of the original Python host.
nonisolated enum Ingest {
    static let maxString = 64_000

    static func entityID(appID: String, schema: String, sourceID: String) -> String {
        let digest = SHA256.hash(data: Data("\(appID)\u{1f}\(schema)\u{1f}\(sourceID)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Projects a raw record onto the schema. A bad optional field is dropped;
    /// a bad or missing required field rejects the record (returns nil).
    static func normalize(_ raw: Any, schema: [String: Any]) -> [String: Any]? {
        guard let record = raw as? [String: Any], let fields = schema["fields"] as? [String: [String: Any]] else { return nil }
        var clean: [String: Any] = [:]
        for (name, spec) in fields {
            var value: Any = NSNull()
            if let s = record[name] as? String, !s.isEmpty, s.count <= maxString {
                switch spec["type"] as? String {
                case "string": value = s
                case "enum": if (spec["values"] as? [String] ?? []).contains(s) { value = s }
                case "datetime": if isoDate(s) != nil { value = s }
                default: break
                }
            }
            if spec["required"] as? Bool == true, value is NSNull { return nil }
            clean[name] = value
        }
        return clean
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Judges whether the profile still understands its source, from statistics
    /// about everything the reader saw (not just the delta being ingested).
    static func canary(rules: [String: Any], viewStats: [String: Any]) -> (ok: Bool, failures: [String]) {
        let total = viewStats["total"] as? Int ?? 0
        let filled = viewStats["filled"] as? [String: Any] ?? [:]
        let minItems = rules["minItems"] as? Int ?? 1
        guard total >= minItems else { return (false, ["items: saw \(total), need >= \(minItems)"]) }
        var failures: [String] = []
        for (field, minimum) in rules["fillRate"] as? [String: Any] ?? [:] {
            let need = (minimum as? NSNumber)?.doubleValue ?? 0
            let rate = Double((filled[field] as? NSNumber)?.intValue ?? 0) / Double(total)
            if rate < need { failures.append("\(field): fill rate \(String(format: "%.2f", rate)) < \(need)") }
        }
        return (failures.isEmpty, failures.sorted())
    }

    /// Thread-hop friendly wrapper: JSON in, JSON out.
    static func run(batchJSON: Data, pageHost: String, accountKey: String? = nil) -> (status: Int, bodyJSON: Data) {
        guard let batch = (try? JSONSerialization.jsonObject(with: batchJSON)) as? [String: Any] else {
            return (400, Data(#"{"error":"invalid batch"}"#.utf8))
        }
        let result = run(batch: batch, pageHost: pageHost, accountKey: accountKey)
        return (result.status, (try? JSONSerialization.data(withJSONObject: result.body)) ?? Data("{}".utf8))
    }

    /// Returns an HTTP-like status and body, the contract the in-page readers already speak.
    static func run(batch: [String: Any], pageHost: String, accountKey: String? = nil, store: BridgeStore = .default, library: ProfileLibrary = .shared) -> (status: Int, body: [String: Any]) {
        let key = "\(batch["profile"] as? String ?? "?")@\(batch["profileVersion"] as? Int ?? -1)"
        guard let profile = library.profiles[key] else { return (404, ["error": "unknown profile \(key)"]) }
        // A page may only speak for profiles that belong to its own origin.
        guard profile.hosts.contains(pageHost) else { return (403, ["error": "profile \(key) does not belong to \(pageHost)"]) }
        // Everything stored is scoped to the account it was read from, not just to the app.
        let scope = accountKey ?? profile.appID
        guard Account.appID(ofKey: scope) == profile.appID else { return (403, ["error": "profile \(key) does not belong to this account"]) }
        if AppSettings.isPaused(scope) { return (423, ["error": "paused", "status": "paused"]) }
        if store.profileStatus(key) == "quarantined" { return (423, ["error": "profile \(key) is quarantined", "status": "quarantined"]) }
        guard let items = batch["items"] as? [Any], items.count <= 2000 else { return (400, ["error": "items must be a list of at most 2000"]) }

        let viewStats = batch["viewStats"] as? [String: Any] ?? ["total": 0, "filled": [String: Any]()]
        let verdict = canary(rules: profile.canary, viewStats: viewStats)
        let fingerprint = batch["fingerprint"] as? String
        let cutoff = AppSettings.cutoff(scope)
        var counts = ["seen": items.count, "inserted": 0, "updated": 0, "unchanged": 0, "rejected": 0, "excluded": 0]
        do {
            let health = try store.recordCanary(key, ok: verdict.ok, fingerprint: fingerprint)
            // A failed canary means this profile's reading of the page is no longer trusted: store nothing.
            if verdict.ok, let schema = library.schemas[profile.schema] {
                for raw in items {
                    guard let record = normalize(raw, schema: schema), let sourceID = record["sourceId"] as? String else {
                        counts["rejected", default: 0] += 1
                        continue
                    }
                    if store.isExcluded(appID: scope, conversationID: record["conversationId"] as? String) {
                        counts["excluded", default: 0] += 1
                        continue
                    }
                    // Older than the user's "Keep" choice: never stored.
                    if let cutoff, let sent = (record["sentAt"] as? String).flatMap(isoDate), sent < cutoff {
                        counts["excluded", default: 0] += 1
                        continue
                    }
                    let id = entityID(appID: scope, schema: profile.schema, sourceID: sourceID)
                    let result = try store.upsert(id: id, appID: scope, schema: profile.schema, record: record,
                                                  profileKey: key, profileSHA: profile.checksum)
                    counts[result.rawValue, default: 0] += 1
                }
            }
            let detail = verdict.failures + (health.drift ? ["fingerprint drift"] : [])
            try store.logBatch(profileKey: key, profileSHA: profile.checksum, appVersion: batch["appVersion"] as? String,
                               fingerprint: fingerprint, counts: counts, canaryOK: verdict.ok, detail: detail)
            var body: [String: Any] = ["canary": verdict.ok ? "ok" : "failed", "detail": detail, "status": health.status]
            for (k, v) in counts { body[k] = v }
            return (verdict.ok ? 200 : 422, body)
        } catch {
            DebugLog.write("ingest: store error \(error)")
            return (500, ["error": "store error"])
        }
    }
}
