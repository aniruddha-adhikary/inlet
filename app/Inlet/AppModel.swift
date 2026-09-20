import AppIntents
import AppKit
import CoreSpotlight
import Foundation
import FoundationModels
import Observation

@Observable
final class AppModel {
    static let shared = AppModel()

    /// Installed by the menu bar label once SwiftUI is up; a request made earlier is honoured then.
    @ObservationIgnored var openWindow: ((String) -> Void)? {
        didSet { if let openWindow { queuedWindows.forEach(openWindow); queuedWindows = [] } }
    }
    @ObservationIgnored private var queuedWindows: [String] = []

    /// The apps the user added, in the order they added them.
    private(set) var sessions: [SourceSession] = []
    var selection: String?
    var showsWelcome = false
    var showsTour = false
    var showsGallery = false

    private(set) var exclusions: [(keyHash: String, appID: String, label: String)] = []
    /// Bumped whenever a per-app preference changes, so views that read `AppSettings` refresh.
    private(set) var settingsRevision = 0

    // Diagnostics only: none of this appears in the main window.
    private(set) var total = 0
    private(set) var pending = 0
    private(set) var indexed = 0
    private(set) var countsByApp: [String: Int] = [:]
    private(set) var lastError: String?

    /// A conversation opened from Siri or Spotlight, with the message to scroll to.
    struct Focus: Equatable { let appID: String; let conversationID: String; let title: String; let messageID: String? }
    var focus: Focus?
    private(set) var focusMessages: [BridgedMessage] = []

    @ObservationIgnored private let store = BridgeStore.default
    @ObservationIgnored private var loop: Task<Void, Never>?

    var availableApps: [AppDescriptor] { AppCatalog.shared.apps }
    var needsAttention: Bool { sessions.contains { status(of: $0).needsUser } }

    // MARK: Status, in the words the interface uses

    enum Status: Equatable {
        case upToDate, updating, paused, signInNeeded, problem

        var needsUser: Bool { self == .signInNeeded || self == .problem }
    }

    func status(of session: SourceSession) -> Status {
        _ = settingsRevision
        #if DEBUG
        // Offline UI tests take the README screenshots: show the everyday state rather than "Paused".
        if CommandLine.arguments.contains("--screenshots") { return .upToDate }
        #endif
        if AppSettings.isPaused(session.descriptor.id) || SourceSession.isOffline { return .paused }
        switch session.state {
        case .connected: return .upToDate
        case .loading: return .updating
        case .needsLogin, .idle: return .signInNeeded
        case .failed: return .problem
        }
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        if Diagnostics.handleLaunchArguments(model: self) { return }
        IndexDelegate.shared.install()
        InletShortcuts.updateAppShortcutParameters()
        AppSettings.migrate(catalog: .shared)
        sessions = AppSettings.added.compactMap { AppCatalog.shared.app($0) }.filter(\.isAvailable).map { SourceSession($0) }
        selection = sessions.first?.descriptor.id
        loop = Task {
            let store = store
            await Task.detached { await Donor.migrateIndexIfNeeded(store: store) }.value
            // Restore earlier sign-ins without showing any window.
            for session in sessions where session.wasConnected && !AppSettings.isPaused(session.descriptor.id) {
                session.start(showWindow: false)
            }
            if !AppSettings.hasSeenWelcome { showsWelcome = true }
            if sessions.isEmpty || !AppSettings.hasSeenWelcome { showMainWindow() }
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func sync() async {
        let store = store
        do {
            await enforceRetention()
            _ = try await Task.detached { try await Donor.donatePending(from: store) }.value
            let c = try await Task.detached { try store.counts() }.value
            (total, pending) = (c.total, c.pending)
            countsByApp = await Task.detached { store.countsByApp() }.value
            exclusions = await Task.detached { store.exclusions() }.value
            if let focus { focusMessages = (try? await Task.detached { try store.conversation(appID: focus.appID, conversationID: focus.conversationID) }.value) ?? [] }
            let held = await Task.detached { await Donor.indexedCount() }.value
            if held != indexed {
                indexed = held
                DebugLog.write("spotlight holds \(held) items; store has \(c.total), \(c.pending) pending")
            }
            lastError = nil
            if !showsWelcome, !AppSettings.hasSeenTour, c.total > 0, c.pending == 0 { showsTour = true }
        } catch {
            lastError = String(describing: error)
            DebugLog.write("sync failed: \(error)")
        }
    }

    // MARK: Apps

    /// Adds an app and opens its sign-in window.
    func add(_ app: AppDescriptor) {
        guard app.isAvailable else { return }
        if !sessions.contains(where: { $0.descriptor.id == app.id }) {
            sessions.append(SourceSession(app))
            AppSettings.added.append(app.id)
        }
        selection = app.id
        showsGallery = false
        session(app.id)?.start(showWindow: true)
    }

    func session(_ id: String) -> SourceSession? { sessions.first { $0.descriptor.id == id } }

    /// Signs out of one app and removes everything it contributed, from this Mac and from Siri and Spotlight.
    func remove(_ session: SourceSession) async {
        await session.disconnect()
        let store = store
        let appID = session.descriptor.id
        sessions.removeAll { $0.descriptor.id == appID }
        AppSettings.forget(appID)
        if selection == appID { selection = sessions.first?.descriptor.id }
        try? await Task.detached {
            try store.deleteEverything(appID: appID)
            try await Donor.rebuildIndex(from: store)
        }.value
        DebugLog.write("removed app \(session.descriptor.name) and its data")
        await sync()
    }

    /// Off: the app stays signed in but is no longer read, and Siri loses what it contributed.
    func setAvailable(_ available: Bool, for session: SourceSession) async {
        let appID = session.descriptor.id
        AppSettings.setPaused(appID, !available)
        settingsRevision += 1
        DebugLog.write("\(session.descriptor.name) \(available ? "resumed" : "paused")")
        let store = store
        if available {
            session.start(showWindow: false)
            try? await Task.detached { try store.resetDonations(appID: appID) }.value
        } else {
            session.pause()
            try? await Task.detached { try await Donor.rebuildIndex(from: store) }.value
        }
        await sync()
    }

    func setKeepDays(_ days: Int, for session: SourceSession) async {
        AppSettings.setKeepDays(session.descriptor.id, days)
        settingsRevision += 1
        await sync()
    }

    private func enforceRetention() async {
        let store = store
        for session in sessions {
            let appID = session.descriptor.id
            guard let cutoff = AppSettings.cutoff(appID) else { continue }
            let removed = (try? await Task.detached { try store.prune(appID: appID, olderThan: cutoff) }.value) ?? []
            guard !removed.isEmpty else { continue }
            try? await Donor.remove(messageIDs: removed)
            DebugLog.write("retention: removed \(removed.count) items from \(session.descriptor.name)")
        }
    }

    /// Signs out everywhere, erases stored content, clears the index and destroys the encryption key.
    func eraseEverything() async {
        for session in sessions { await session.disconnect() }
        for session in sessions { AppSettings.forget(session.descriptor.id) }
        sessions = []
        selection = nil
        focus = nil
        let store = store
        try? await Task.detached {
            try await Donor.clearIndex()
            try store.deleteEverything()
        }.value
        Vault.destroyKey()
        DebugLog.write("erased all data; key destroyed (takes effect for new content on next launch)")
        await sync()
    }

    // MARK: Opening results from Siri and Spotlight

    /// Opens the conversation a message belongs to, scrolled to that message.
    func reveal(messageID: String) async {
        let store = store
        guard let m = try? await Task.detached(operation: { try store.messages(ids: [messageID]).first }).value,
              let conversationID = m.conversationID else { return showMainWindow() }
        await open(Focus(appID: m.appID, conversationID: conversationID, title: m.conversationName ?? "Conversation", messageID: m.id))
    }

    func reveal(conversationEntityID: String, title: String) async {
        // Conversation entity ids are "<appID>:<conversationID>".
        guard let split = conversationEntityID.firstIndex(of: ":") else { return showMainWindow() }
        let appID = String(conversationEntityID[..<split]), conversationID = String(conversationEntityID[conversationEntityID.index(after: split)...])
        await open(Focus(appID: appID, conversationID: conversationID, title: title, messageID: nil))
    }

    private func open(_ focus: Focus) async {
        let store = store
        focusMessages = (try? await Task.detached { try store.conversation(appID: focus.appID, conversationID: focus.conversationID) }.value) ?? []
        self.focus = focus
        if session(focus.appID) != nil { selection = focus.appID }
        DebugLog.write("intent: open conversation (\(focusMessages.count) messages)")
        showMainWindow()
    }

    /// Hides one chat from Siri: deletes its stored messages and removes them from Siri and Spotlight.
    func exclude(_ focus: Focus) async {
        let store = store
        let removed = (try? await Task.detached { try store.exclude(appID: focus.appID, conversationID: focus.conversationID, label: focus.title) }.value) ?? []
        try? await Donor.remove(messageIDs: removed)
        DebugLog.write("excluded a conversation (\(removed.count) messages removed)")
        self.focus = nil
        await sync()
    }

    func include(keyHash: String) async {
        let store = store
        try? await Task.detached { try store.include(keyHash: keyHash) }.value
        await sync()
    }

    // MARK: Windows

    func showMainWindow() { show(window: "main") }
    func showDiagnostics() { show(window: "diagnostics") }

    private func show(window id: String) {
        if let openWindow { openWindow(id) } else { queuedWindows.append(id) }
    }
}
