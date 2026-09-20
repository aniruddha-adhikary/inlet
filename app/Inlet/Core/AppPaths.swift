import Foundation

/// Where Inlet keeps its own data. Inside the sandbox container this is
/// ~/Library/Containers/<bundle id>/Data/Library/Application Support/Inlet.
nonisolated enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Inlet", isDirectory: true)
        // The app was called Chatbridge before 0.4: keep what it stored.
        let legacy = base.appendingPathComponent("Chatbridge", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static var database: URL { supportDirectory.appendingPathComponent("bridge.db") }
    static var log: URL { supportDirectory.appendingPathComponent("app.log") }

    /// Owner-only, and never in a backup of someone else's machine state.
    static func lockDown(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = url
        try? copy.setResourceValues(values)
    }
}
