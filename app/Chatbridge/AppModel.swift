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
    @ObservationIgnored var openMainWindow: (() -> Void)? {
        didSet { if wantsMainWindow, let openMainWindow { wantsMainWindow = false; openMainWindow() } }
    }
    @ObservationIgnored private var wantsMainWindow = false
    let sessions: [SourceSession] = SourceSession.catalog.map { SourceSession($0) }
    private(set) var total = 0
    private(set) var pending = 0
    private(set) var countsByApp: [String: Int] = [:]
    private(set) var lastError: String?
    private(set) var recent: [BridgedMessage] = []
    private(set) var exclusions: [(keyHash: String, appID: String, label: String)] = []

    /// A conversation opened from Siri or Spotlight, with the message to scroll to.
    struct Focus: Equatable { let appID: String; let conversationID: String; let title: String; let messageID: String? }
    var focus: Focus?
    private(set) var focusMessages: [BridgedMessage] = []

    @ObservationIgnored private let store = BridgeStore.default
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastIndexed = -2

    var anyConnected: Bool { sessions.contains { $0.state == .connected } }

    func start() {
        guard loop == nil else { return }
        if Diagnostics.handleLaunchArguments(model: self) { return }
        IndexDelegate.shared.install()
        ChatbridgeShortcuts.updateAppShortcutParameters()
        loop = Task {
            let store = store
            await Task.detached { await Donor.migrateIndexIfNeeded(store: store) }.value
            // Restore earlier sign-ins without showing any window; never open a source the user hasn't connected.
            for session in sessions where session.wasConnected { session.start(showWindow: false) }
            if !sessions.contains(where: \.wasConnected) { showMainWindow() } // first run: show the sources
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func sync() async {
        let store = store
        do {
            _ = try await Task.detached { try await Donor.donatePending(from: store) }.value
            let c = try await Task.detached { try store.counts() }.value
            (total, pending) = (c.total, c.pending)
            countsByApp = await Task.detached { store.countsByApp() }.value
            recent = (try? await Task.detached { try store.recentlyDonated(limit: 20) }.value) ?? []
            exclusions = await Task.detached { store.exclusions() }.value
            if let focus { focusMessages = (try? await Task.detached { try store.conversation(appID: focus.appID, conversationID: focus.conversationID) }.value) ?? [] }
            let indexed = await Task.detached { await Donor.indexedCount() }.value
            if indexed != lastIndexed {
                lastIndexed = indexed
                DebugLog.write("spotlight holds \(indexed) items; store has \(c.total), \(c.pending) pending")
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Disconnects one source and removes everything it contributed, from the store and from Siri/Spotlight.
    func remove(_ session: SourceSession) async {
        await session.disconnect()
        let store = store
        let appID = session.descriptor.id
        try? await Task.detached {
            try store.deleteEverything(appID: appID)
            try await Donor.rebuildIndex(from: store)
        }.value
        DebugLog.write("removed source \(session.descriptor.name) and its data")
        await sync()
    }

    /// Signs out everywhere, erases stored content, clears the index and destroys the encryption key.
    func eraseEverything() async {
        for session in sessions { await session.disconnect() }
        let store = store
        try? await Task.detached {
            try await Donor.clearIndex()
            try store.deleteEverything()
        }.value
        Vault.destroyKey()
        DebugLog.write("erased all data; key destroyed (takes effect for new content on next launch)")
        await sync()
    }

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
        DebugLog.write("intent: open conversation (\(focusMessages.count) messages)")
        showMainWindow()
    }

    /// Stops indexing one chat: deletes its stored messages and removes them from Siri and Spotlight.
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

    func showMainWindow() {
        if let openMainWindow { openMainWindow() } else { wantsMainWindow = true }
    }

}
