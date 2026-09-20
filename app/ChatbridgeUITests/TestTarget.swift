import Foundation

enum TestTarget {
    /// The UI test bundle id is "<app bundle id>.uitests" (see the project's build settings),
    /// so the app's id never has to be hard-coded in the tests.
    static let appBundleID: String = {
        final class Marker {}
        let own = Bundle(for: Marker.self).bundleIdentifier ?? ""
        return own.hasSuffix(".uitests") ? String(own.dropLast(".uitests".count)) : own
    }()
}
