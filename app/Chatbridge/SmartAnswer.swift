import CoreSpotlight
import Foundation
import FoundationModels

/// Answers a natural-language question about bridged messages by letting
/// Apple's on-device language model search this app's own Spotlight index
/// (`SpotlightSearchTool`, new in the 27 releases). Read-only: the model can
/// only query the index. Nothing leaves the Mac.
nonisolated enum SmartAnswer {
    static let instructions = """
        You answer questions about the user's chat messages, which are indexed from their messaging apps. \
        Use the search tool to find relevant messages before answering. Search mainly by words in the message \
        text; only filter by author when the user clearly names who SENT the message (people mentioned inside \
        a message are not its author). If a search returns nothing, retry with fewer or different words. \
        Each item's text is the message, its author is the sender, its container title is the chat name, \
        and it has a sent date. \
        its text is the message, and it has a sent date. Answer briefly and directly, naming who said what, \
        in which chat, and when. If the search finds nothing relevant, say you couldn't find it. \
        Never invent messages. Never mention bundle identifiers or internal ids (anything that looks like com.example.app); if you don't know the chat's name, leave it out.
        """

    static func answer(_ question: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            DebugLog.write("smart answer: on-device model unavailable (\(SystemLanguageModel.default.availability))")
            return nil
        }
        let tool = SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight(.init(fetchAttributes: [
                .textContent, .authorNames, .containerTitle, .contentCreationDate,
            ]))],
            guide: .focused(.communications(.init(
                authors: [.authorNames],
                sent: [.contentCreationDate],
                topic: [.textContent, .contentDescription])))))
        let session = LanguageModelSession(tools: [tool], instructions: instructions)
        let started = Date()
        do {
            let response = try await session.respond(to: question)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.write("smart answer: ok in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(text.count) chars")
            return text.isEmpty ? nil : text
        } catch {
            DebugLog.write("smart answer: failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error)")
            return nil
        }
    }
}
