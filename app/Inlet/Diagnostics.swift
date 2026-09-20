import CoreSpotlight
import Foundation
import FoundationModels

/// Command-line entry points for development and support. None of them print message content
/// except `--smart-test`, which is meant for seeded fixture data.
enum Diagnostics {
    /// Returns true when a diagnostic flag was handled and normal startup should not continue.
    static func handleLaunchArguments(model: AppModel) -> Bool {
        let args = CommandLine.arguments
        #if DEBUG
        // Used by the UI tests: seed fictional data, then start normally.
        if args.contains("--with-fixtures") { _ = Fixtures.seed() }
        #endif
        if let i = args.firstIndex(of: "--smart-test"), args.count > i + 1 {
            let question = args[i + 1]
            Task {
                print("availability: \(SystemLanguageModel.default.availability)")
                let answer = await Task.detached { await SmartAnswer.answer(question) }.value
                print("answer: \(answer ?? "<nil>")")
                exit(0)
            }
            return true
        }
        if args.contains("--wipe-index") {
            Task {
                try? await Donor.clearIndex()
                DebugLog.write("index wiped on request for \(Bundle.main.bundleIdentifier ?? "?")")
                exit(0)
            }
            return true
        }
        if args.contains("--seed-fixtures") {
            Task {
                let n = await Task.detached { Fixtures.seed() }.value
                _ = try? await Donor.donatePending(from: .default)
                print("seeded \(n) fixture messages")
                exit(0)
            }
            return true
        }
        if args.contains("--remove-fixtures") {
            Task {
                let store = BridgeStore.default
                for appID in store.countsByApp().keys where appID.hasPrefix("dev.inlet.") {
                    try? store.deleteEverything(appID: appID)
                }
                try? await Donor.rebuildIndex(from: store)
                print("fixtures removed; index rebuilt")
                exit(0)
            }
            return true
        }
        if args.contains("--verify-storage") {
            print(StorageAudit.report())
            exit(0)
        }
        if let i = args.firstIndex(of: "--log-tail") {
            let n = args.count > i + 1 ? Int(args[i + 1]) ?? 20 : 20
            let text = (try? String(contentsOf: AppPaths.log, encoding: .utf8)) ?? ""
            print(text.split(separator: "\n").suffix(n).joined(separator: "\n"))
            exit(0)
        }
        if let i = args.firstIndex(of: "--release"), args.count > i + 1 {
            try? BridgeStore.default.release(args[i + 1])
            print("released \(args[i + 1])")
            exit(0)
        }
        if args.contains("--status") {
            let store = BridgeStore.default
            let c = (try? store.counts()) ?? (0, 0)
            print("messages: \(c.0) (pending donation: \(c.1))")
            for (app, n) in store.countsByApp().sorted(by: { $0.key < $1.key }) { print("  \(app): \(n)") }
            for s in store.profileStates() { print("  profile \(s.key): \(s.status)") }
            print("data: \(AppPaths.supportDirectory.path)")
            exit(0)
        }
        return false
    }
}

/// Fictional records that exercise the real ingest path (profile, canary, normalize, seal, store).
nonisolated enum Fixtures {
    static func seed() -> Int {
        func msg(_ id: String, _ chatID: String, _ chat: String, _ sender: String, _ out: Bool, _ body: String, _ at: String) -> [String: Any] {
            ["sourceId": id, "conversationId": chatID, "conversationName": chat, "sender": sender,
             "direction": out ? "outgoing" : "incoming", "body": body, "sentAt": at]
        }
        let items: [[String: Any]] = [
            msg("fx1", "111@c.us", "Flare", "Flare", false, "Did you watch Dune Part Three yet?", "2026-09-19T12:32:00Z"),
            msg("fx2", "111@c.us", "Flare", "Me", true, "Not yet, booking IMAX for Saturday.", "2026-09-19T12:33:00Z"),
            msg("fx3", "111@c.us", "Flare", "Flare", false, "Get me one too. Also the landlord wants the rent by the 5th.", "2026-09-19T12:35:00Z"),
            msg("fx4", "222@g.us", "Flat hunt", "Broker Raj", false, "The 2BHK in Indiranagar is 48k, visit at 6pm.", "2026-09-20T10:29:00Z"),
            msg("fx5", "222@g.us", "Flat hunt", "Me", true, "Floor plan of the flat", "2026-09-20T10:30:00Z"),
        ]
        var filled: [String: Int] = [:]
        for item in items { for (k, _) in item { filled[k, default: 0] += 1 } }
        let batch: [String: Any] = [
            "profile": "demo-store", "profileVersion": 1, "fingerprint": "fixture", "appVersion": "fixture",
            "items": items, "viewStats": ["total": items.count, "filled": filled],
        ]
        let result = Ingest.run(batch: batch, pageHost: "127.0.0.1:8787")
        DebugLog.write("fixtures: ingest status \(result.status)")
        return (result.body["inserted"] as? Int ?? 0) + (result.body["unchanged"] as? Int ?? 0) + (result.body["updated"] as? Int ?? 0)
    }
}


/// Self-audit of what is on disk. The sandbox container is unreadable to other processes,
/// so the app checks its own storage: permissions, and that known fixture words never appear in clear.
nonisolated enum StorageAudit {
    static func report() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        let dir = AppPaths.supportDirectory
        func mode(_ url: URL) -> String {
            ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
        }
        lines.append("directory \(mode(dir)) \(dir.lastPathComponent)")
        var blob = Data()
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("bridge.db") {
            let url = dir.appendingPathComponent(name)
            lines.append("file \(mode(url)) \(name) (\(((try? Data(contentsOf: url))?.count ?? 0)) bytes)")
            blob.append((try? Data(contentsOf: url)) ?? Data())
        }
        let count = (try? BridgeStore.default.counts().total) ?? 0
        lines.append("stored messages: \(count)")
        for word in ["Dune", "landlord", "Indiranagar", "Flare"] {
            lines.append("plaintext '\(word)' in database files: \(blob.range(of: Data(word.utf8)) == nil ? "absent" : "PRESENT")")
        }
        // A second, independent check: the first stored body must not appear in clear either.
        if let body = try? BridgeStore.default.allMessages().first(where: { ($0.body ?? "").count > 12 })?.body {
            lines.append("first stored message body in clear: \(blob.range(of: Data(body.utf8)) == nil ? "absent" : "PRESENT")")
        }
        lines.append("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        return lines.joined(separator: "\n")
    }
}
