import AppIntents
import CoreSpotlight

/// Turns bridged records into App Schema entities and hands them to the
/// Spotlight semantic index, which is what Siri AI searches.
nonisolated enum Donor {
    static func appName(_ appID: String) -> String {
        switch appID {
        case "net.whatsapp.web": "WhatsApp"
        case "org.telegram.web": "Telegram"
        case let id where id.hasPrefix("dev.chatbridge."): "Demo"
        default: appID
        }
    }

    static func person(for m: BridgedMessage) -> MessagePerson {
        let name = m.sender ?? (m.outgoing ? "Me" : "Unknown")
        // Keyed by the source's stable sender id: display names resolve lazily and change over time.
        let key = "\(m.appID):\(m.senderID ?? name)"
        return MessagePerson(
            id: key,
            person: IntentPerson(
                identifier: .applicationDefined(key),
                name: .displayName(name),
                handle: IntentPerson.Handle(applicationDefined: name, label: appName(m.appID)),
                isMe: m.outgoing))
    }

    static func conversationID(for m: BridgedMessage) -> String {
        "\(m.appID):\(m.conversationID ?? m.conversationName ?? "unknown")"
    }

    static func conversation(for m: BridgedMessage, recipients: [MessagePerson] = []) -> ConversationEntity {
        let chatName = m.conversationName ?? "Conversation"
        return ConversationEntity(
            id: conversationID(for: m),
            recipients: recipients,
            displayName: "\(chatName) (\(appName(m.appID)))",
            previewText: AttributedString(m.body ?? ""),
            conversationName: chatName,
            isRead: true,
            attributes: [],
            dateLastActive: m.sentAt)
    }

    /// Every person and conversation implied by the stored messages.
    static func graph(from store: BridgeStore) throws -> (persons: [MessagePerson], conversations: [ConversationEntity]) {
        var persons: [String: MessagePerson] = [:]
        var latest: [String: BridgedMessage] = [:]
        var members: [String: [String: MessagePerson]] = [:]
        for m in try store.allMessages() {
            let p = person(for: m)
            persons[p.id] = p
            let cid = conversationID(for: m)
            members[cid, default: [:]][p.id] = p
            if (m.sentAt ?? .distantPast) >= (latest[cid]?.sentAt ?? .distantPast) { latest[cid] = m }
        }
        let conversations = latest.map { cid, m in conversation(for: m, recipients: Array((members[cid] ?? [:]).values)) }
        return (Array(persons.values), conversations)
    }

    static func entity(from m: BridgedMessage) -> MessageEntity {
        let author = person(for: m)
        let conversation = conversation(for: m)
        return MessageEntity(
            id: m.id,
            messageType: .unspecified,
            author: author,
            isRead: true,
            attributes: [],
            conversation: conversation,
            date: m.sentAt ?? .distantPast,
            subject: nil,
            body: m.body.map { AttributedString($0) },
            attachments: [],
            audioMessage: nil,
            customAttachments: [],
            locations: [],
            links: [],
            messageEffect: nil,
            reaction: nil,
            referencedMessage: nil,
            notificationIdentifier: nil)
    }

    static func donate(_ batch: [BridgedMessage], from store: BridgeStore) async throws {
        guard !batch.isEmpty else { return }
        try await Donor.index.indexAppEntities(batch.map(entity(from:)))
        try store.markDonated(batch)
    }

    static func redonateEverything(from store: BridgeStore) async throws {
        try store.resetDonations()
        let n = try await donatePending(from: store)
        if n == 0 { try await donateGraph(from: store) }
    }

    /// Bump whenever the donated shape changes (titles, attributes, entity
    /// types). On mismatch everything this app ever gave Spotlight is wiped
    /// and re-donated, so Siri never sees a mix of old and new shapes.
    static let indexShapeVersion = 8

    /// Apple: "use a named CSSearchableIndex and not the default index".
    nonisolated(unsafe) static let index = CSSearchableIndex(name: (Bundle.main.bundleIdentifier ?? "chatbridge") + ".index")

    static func migrateIndexIfNeeded(store: BridgeStore) async {
        let key = "indexShapeVersion"
        guard UserDefaults.standard.integer(forKey: key) != indexShapeVersion else { return }
        do {
            try await clearIndex()
            try store.resetDonations()
            UserDefaults.standard.set(indexShapeVersion, forKey: key)
            DebugLog.write("index wiped for shape v\(indexShapeVersion); re-donating everything")
        } catch {
            DebugLog.write("index wipe failed: \(error)")
        }
    }

    static func donateGraph(from store: BridgeStore) async throws {
        let g = try graph(from: store)
        try await Donor.index.indexAppEntities(g.persons)
        try await Donor.index.indexAppEntities(g.conversations)
    }

    /// Returns how many records were donated.
    static func donatePending(from store: BridgeStore) async throws -> Int {
        var donated = 0
        while true {
            let batch = try store.pending()
            if batch.isEmpty {
                if donated > 0 { try await donateGraph(from: store) }
                return donated
            }
            try await donate(batch, from: store)
            donated += batch.count
        }
    }

    /// Asks Spotlight what it actually holds for this app (count only).
    static func indexedCount(matching queryString: String = "textContent == '*'cd || title == '*'cd") async -> Int {
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        let query = CSSearchQuery(queryString: queryString, queryContext: context)
        var n = 0
        do { for try await _ in query.results { n += 1 } } catch { return -1 }
        return n
    }

    static func remove(messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        try await index.deleteAppEntities(identifiedBy: messageIDs, ofType: MessageEntity.self)
    }

    /// Removes everything this app ever gave Spotlight (both the named index and the old default one).
    static func clearIndex() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
        try await index.deleteAllSearchableItems()
    }

    /// Clears the index and donates whatever the store still holds.
    static func rebuildIndex(from store: BridgeStore) async throws {
        try await clearIndex()
        try store.resetDonations()
        _ = try await donatePending(from: store)
    }
}
