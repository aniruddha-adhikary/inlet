import Foundation

/// Diagnostic trace in the app's own support folder. Never logs message content,
/// names or search words: only counts, sizes, states and profile keys.
nonisolated enum DebugLog {
    private static let lock = NSLock()

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = AppPaths.log
        let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            AppPaths.lockDown(url)
        }
    }
}
