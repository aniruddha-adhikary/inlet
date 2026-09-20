import AppIntentsTesting
import XCTest

/// Drives the real UI the way a person would and saves screenshots for review.
/// Never signs in anywhere and never confirms a destructive action.
final class UISmokeTests: XCTestCase {
    /// Screenshots are kept as attachments in the .xcresult bundle (export with xcresulttool).
    private func snap(_ name: String, _ element: XCUIElement? = nil) {
        let image = (element?.exists == true ? element!.screenshot() : XCUIScreen.main.screenshot())
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSourcesWindowAndEraseDialog() throws {
        let app = XCUIApplication()
        app.launch()

        // Menu bar item -> "Open Chatbridge"
        let status = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "menu bar item missing")
        status.click()
        snap("1-menu")
        let open = app.menuItems["Open Chatbridge"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        let window = app.windows["Chatbridge"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window did not open")
        XCTAssertTrue(window.staticTexts["WhatsApp"].exists)
        XCTAssertTrue(window.staticTexts["Telegram"].exists)
        snap("2-sources", window)

        // Destructive action must ask first; cancel it.
        window.buttons["Erase everything…"].click()
        let confirm = window.sheets.buttons["Erase everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "erase must ask for confirmation")
        snap("3-erase-confirm", window)
        window.sheets.buttons["Cancel"].click()
        XCTAssertFalse(confirm.waitForExistence(timeout: 2))
    }

    func testConnectOpensContainedSignInWindow() throws {
        let app = XCUIApplication()
        app.launch()
        app.menuBars.statusItems.firstMatch.click()
        app.menuItems["Open Chatbridge"].click()
        let window = app.windows["Chatbridge"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        guard window.buttons["Connect"].firstMatch.exists else { throw XCTSkip("a source is already connected") }
        window.buttons["Connect"].firstMatch.click()

        let signIn = app.windows["Sign in to WhatsApp"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "sign-in window did not open")
        // Give the page time to render its QR; we only look, never interact with it.
        _ = signIn.webViews.firstMatch.waitForExistence(timeout: 20)
        sleep(8)
        snap("4-whatsapp-signin", signIn)
    }

    /// Tapping a Siri/Spotlight result must land in the conversation, at that message, with context.
    @MainActor
    func testOpeningAMessageShowsItsConversation() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--with-fixtures"]
        app.launch()
        let definitions = IntentDefinitions(bundleIdentifier: TestTarget.appBundleID)
        let hits = try await definitions.entities["MessageEntity"].spotlightQuery("landlord wants the rent")
        let target = try XCTUnwrap(hits.first, "fixture message not indexed")
        _ = try await definitions.intents["OpenMessageIntent"].makeIntent(target: target).run()

        let window = app.windows["Chatbridge"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "opening a message must show the window")
        XCTAssertTrue(window.staticTexts["Flare"].firstMatch.waitForExistence(timeout: 5), "conversation title missing")
        // Neighbouring messages from the same chat give the context.
        XCTAssertTrue(window.staticTexts["Did you watch Dune Part Three yet?"].exists)
        XCTAssertTrue(window.staticTexts["Get me one too. Also the landlord wants the rent by the 5th."].exists)
        snap("5-conversation", window)

        let cleaner = XCUIApplication()
        cleaner.launchArguments = ["--remove-fixtures"]
        cleaner.launch()
        _ = cleaner.wait(for: .notRunning, timeout: 20)
    }
}
