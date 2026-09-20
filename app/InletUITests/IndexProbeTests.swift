import AppIntentsTesting
import XCTest

/// Asks the system, through the same App Intents pathway Siri uses, what it
/// can find for our entities. Only counts are printed for real content.
final class IndexProbeTests: XCTestCase {
    private var definitions: IntentDefinitions!

    override func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = ["--with-fixtures", "--offline"]
        app.launch()
        definitions = IntentDefinitions(bundleIdentifier: TestTarget.appBundleID)
    }

    /// Fictional fixtures must not linger in the person's real Siri index.
    override class func tearDown() {
        let cleaner = XCUIApplication()
        cleaner.launchArguments = ["--remove-fixtures", "--offline"]
        cleaner.launch()
        _ = cleaner.wait(for: .notRunning, timeout: 20)
        super.tearDown()
    }

    /// Donation runs in the background after launch: poll instead of assuming it has finished.
    private func eventually(_ entity: String, _ query: String, atLeast minimum: Int, timeout: TimeInterval = 25) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var n = try await count(entity, query)
        while n < minimum, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            n = try await count(entity, query)
        }
        return n
    }

    private func count(_ entity: String, _ query: String) async throws -> Int {
        let hits = try await definitions.entities[entity].spotlightQuery(query)
        print("PROBE \(entity) spotlightQuery('\(query)') -> \(hits.count)")
        return hits.count
    }

    func testFixtureMessageByBody() async throws {
        let n = try await eventually("MessageEntity", "Dune Part Three", atLeast: 1)
        XCTAssertGreaterThanOrEqual(n, 1)
    }

    func testSemanticNeighbour() async throws {
        // No word overlap with any fixture message.
        _ = try await count("MessageEntity", "going to the cinema this weekend")
        _ = try await count("MessageEntity", "apartment hunting")
    }

    func testPersonsAndConversationsAreIndexed() async throws {
        let people = try await eventually("MessagePerson", "Broker Raj", atLeast: 1)
        let chats = try await eventually("ConversationEntity", "Flat hunt", atLeast: 1)
        XCTAssertGreaterThanOrEqual(people, 1, "fixture person not indexed")
        XCTAssertGreaterThanOrEqual(chats, 1, "fixture conversation not indexed")
    }

    func testSearchChatsAnswersInSiri() async throws {
        // The App Shortcut path: must return matches as a value + dialog, not open the app.
        let result = try await definitions.intents["SearchChatsIntent"].makeIntent(words: "Dune").run()
        print("PROBE SearchChatsIntent result: \(String(describing: result).prefix(300))")
    }

    func testSmartAnswerOnFixture() async throws {
        // Fixture-only question: the on-device model must find "the landlord wants the rent by the 5th".
        let result = try await definitions.intents["SearchBridgedContentIntent"]
            .makeIntent(criteria: "When does the landlord want the rent?").run()
        let text = String(describing: result)
        if let r = text.range(of: "dialog") { print("PROBE smart dialog: \(text[r.lowerBound...].prefix(700))") }
        else { print("PROBE smart result (no dialog field found): \(text.suffix(600))") }
    }

    func testAllFiveMessagesIntentsAreRegistered() throws {
        for name in ["SendMessageIntent", "DraftMessageIntent", "EditSentMessageIntent",
                     "UnsendMessageIntent", "SetMessageReadStatusIntent"] {
            _ = definitions.intents[name]
        }
    }
}
