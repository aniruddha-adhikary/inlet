import AppIntents

// Read-only navigation: Siri and Spotlight can open a bridged item or hand a
// search to the app. Nothing here touches the source app's data.

/// One answer for every search path Siri may choose, spoken inside Siri.
nonisolated enum BridgeAnswer {
    static func search(_ query: String, via path: String) async -> (entities: [MessageEntity], dialog: IntentDialog) {
        let store = BridgeStore.default
        let hits = (try? await Task.detached { try store.search(query) }.value) ?? []
        DebugLog.write("intent: \(path) (\(query.count) chars) -> \(hits.count) hits")
        // Prefer an answer reasoned by Apple's on-device model over our index;
        // the keyword summary below is the fallback.
        if let smart = await SmartAnswer.answer(query) {
            return (hits.map(Donor.entity(from:)), IntentDialog(stringLiteral: smart))
        }
        guard !hits.isEmpty else {
            return ([], "I couldn't find anything mentioning \(query).")
        }
        let day = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let lines = hits.prefix(3).map { m in
            "\(m.sender ?? "Someone") in \(m.conversationName ?? "a chat")\(m.sentAt.map { ", " + $0.formatted(day) } ?? ""): \(m.body ?? "")"
        }
        let more = hits.count > 3 ? " Plus \(hits.count - 3) more." : ""
        let text = "I found \(hits.count) message\(hits.count == 1 ? "" : "s") mentioning \(query). " + lines.joined(separator: " ") + more
        return (hits.map(Donor.entity(from:)), IntentDialog(stringLiteral: text))
    }
}

@AppIntent(schema: .system.open)
struct OpenMessageIntent: OpenIntent {
    var target: MessageEntity

    func perform() async throws -> some IntentResult {
        await AppModel.shared.reveal(messageID: target.id)
        return .result()
    }
}

@AppIntent(schema: .system.open)
struct OpenConversationIntent: OpenIntent {
    var target: ConversationEntity

    func perform() async throws -> some IntentResult {
        await AppModel.shared.reveal(conversationEntityID: target.id, title: target.conversationName ?? target.displayName)
        return .result()
    }
}

// Siri AI's planner routes "search ... in Inlet" through this schema and
// nothing else (App Shortcut phrases are ignored by it). Apple requires the
// schema to open the app; Inlet is a windowless menu bar app, so that
// "open" shows nothing and the answer is spoken by Siri instead.
@AppIntent(schema: .system.searchInApp)
struct SearchBridgedContentIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult & ReturnsValue<[MessageEntity]> & ProvidesDialog {
        let answer = await BridgeAnswer.search(criteria.term, via: "searchInApp, answered in Siri")
        return .result(value: answer.entities, dialog: answer.dialog)
    }
}

/// The search the App Shortcut phrases point at. Answers inside Siri: it never
/// opens the app, and hands the matching messages back as entities so Siri can
/// read them out or reason over them.
struct SearchChatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Inlet"
    static let description = IntentDescription("Searches what Inlet has brought in from your other apps.")
    static let openAppWhenRun = false

    @Parameter(title: "Words", requestValueDialog: "What should I search for?")
    var words: String

    func perform() async throws -> some IntentResult & ReturnsValue<[MessageEntity]> & ProvidesDialog {
        let answer = await BridgeAnswer.search(words, via: "app shortcut, answered in Siri")
        return .result(value: answer.entities, dialog: answer.dialog)
    }
}

/// Registers the app's name and phrases with Siri. Without App Shortcuts,
/// linkd marks the bundle "processed" with nothing for Siri to route to.
struct InletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchChatsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my chats in \(.applicationName)",
                "Find messages in \(.applicationName)",
                "Search for a message in \(.applicationName)",
            ],
            shortTitle: "Search Inlet",
            systemImageName: "magnifyingglass")
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: ["Open conversation in \(.applicationName)"],
            shortTitle: "Open Conversation",
            systemImageName: "person.circle")
    }
}
