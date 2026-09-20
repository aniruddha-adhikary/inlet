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

    /// The welcome and the tour appear on their own for a new user; tests ask for them explicitly.
    private static let introSeen = ["--offline", "--screenshots", "-welcome.seen", "YES", "-tour.seen", "YES"]
    private static let iconShown = ["-settings.hideMenuBarIcon", "NO"]

    /// The "?" menu in the window's toolbar.
    private func help(_ window: XCUIElement, _ item: String) {
        let button = window.toolbars.descendants(matching: .any)["help-menu"].firstMatch
        button.click()
        button.menuItems[item].click()
    }

    private func openMainWindow(_ app: XCUIApplication) -> XCUIElement {
        let status = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "menu bar item missing")
        status.click()
        let open = app.menuItems["Open Inlet"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let window = app.windows["Inlet"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window did not open")
        return window
    }

    func testMainWindowShowsNoStatisticsAndPrivacyAsksBeforeErasing() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + Self.iconShown
        app.launch()
        let window = openMainWindow(app)
        snap("1-main", window)
        // The main window is not a dashboard: counts and sync details live in Diagnostics.
        XCTAssertFalse(window.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'waiting to be indexed' OR label CONTAINS[c] 'last sync'")).firstMatch.exists)

        window.outlines.staticTexts["Privacy"].click()
        XCTAssertTrue(window.staticTexts["Stays on This Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Read Only"].exists)
        snap("2-privacy", window)

        // Destructive action must ask first; cancel it.
        window.buttons["Erase All Data…"].click()
        let confirm = window.sheets.buttons["Erase All Data"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "erase must ask for confirmation")
        snap("3-erase-confirm", window)
        window.sheets.buttons["Cancel"].click()
        XCTAssertFalse(confirm.waitForExistence(timeout: 2))
    }

    func testGalleryListsAppsFromTheCatalog() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + Self.iconShown
        app.launch()
        let window = openMainWindow(app)
        window.buttons["add-app"].click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["gallery-net.whatsapp.web"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["gallery-org.telegram.web"].exists)
        // Apps that are not readable yet are shown, but can't be added.
        XCTAssertFalse(sheet.buttons["gallery-com.slack.web"].isEnabled)
        snap("4-gallery", window)
        sheet.buttons["Cancel"].click()
    }

    func testWelcomeAndTourFromTheHelpMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + Self.iconShown
        app.launch()
        let window = openMainWindow(app)

        help(window, "Welcome to Inlet")
        XCTAssertTrue(window.sheets.staticTexts["Welcome to Inlet"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.sheets.firstMatch.staticTexts["Stays on This Mac"].exists, "the privacy promise comes before any sign-in")
        snap("5-welcome", window)
        window.sheets.buttons["Continue"].click()
        if window.sheets.buttons["Cancel"].waitForExistence(timeout: 2) { window.sheets.buttons["Cancel"].click() } // gallery, when no app is added yet

        help(window, "Take the Tour")
        XCTAssertTrue(window.sheets.staticTexts["Ask Siri"].waitForExistence(timeout: 5))
        snap("6-tour-1", window)
        app.activate() // a click on an inactive window only activates it
        window.sheets.buttons["Next"].click()
        XCTAssertTrue(window.sheets.staticTexts["Search with Spotlight"].waitForExistence(timeout: 5))
        snap("7-tour-2", window)
        window.sheets.buttons["Next"].click()
        XCTAssertTrue(window.sheets.staticTexts["See It in Context"].waitForExistence(timeout: 5))
        snap("8-tour-3", window)
        window.sheets.buttons["Done"].click()
        XCTAssertFalse(window.sheets.firstMatch.waitForExistence(timeout: 2))
    }

    /// Hiding the menu bar icon must not lock the user out: opening the app shows the window.
    func testWindowOpensByItselfWhenTheMenuBarIconIsHidden() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + ["-settings.hideMenuBarIcon", "YES"]
        app.launch()
        XCTAssertTrue(app.windows["Inlet"].waitForExistence(timeout: 10), "no window and no menu bar icon: the app is unreachable")
        XCTAssertFalse(app.menuBars.statusItems.firstMatch.exists)
    }

    func testSettingsHelpAndAbout() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + Self.iconShown
        app.launch()
        let window = openMainWindow(app)
        XCTAssertTrue(window.textFields["account-name"].firstMatch.waitForExistence(timeout: 5), "accounts can be named")

        help(window, "Inlet Help")
        let helpWindow = app.windows["Inlet Help"]
        XCTAssertTrue(helpWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(helpWindow.staticTexts["Use More Than One Account"].firstMatch.exists)
        snap("10-help", helpWindow)

        app.activate()
        help(window, "About Inlet")
        let about = app.windows["About Inlet"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        XCTAssertTrue(about.links["adhikary.net"].exists)
        snap("12-about", about)

        app.activate()
        help(window, "Settings…")
        let settings = app.windows["Inlet Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.descendants(matching: .any)["Show Inlet in the menu bar"].firstMatch.exists, "Settings must offer hiding the menu bar icon")
        snap("11-settings", settings)
    }

    func testDiagnosticsIsSeparateFromTheMainWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.introSeen + Self.iconShown
        app.launch()
        let window = openMainWindow(app)
        help(window, "Diagnostics")
        let diagnostics = app.windows["Diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        XCTAssertTrue(diagnostics.staticTexts["Waiting for Spotlight"].exists)
    }

    /// Tapping a Siri/Spotlight result must land in the conversation, at that message, with context.
    @MainActor
    func testOpeningAMessageShowsItsConversation() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--with-fixtures"] + Self.introSeen
        app.launch()
        let definitions = IntentDefinitions(bundleIdentifier: TestTarget.appBundleID)
        let hits = try await definitions.entities["MessageEntity"].spotlightQuery("landlord wants the rent")
        let target = try XCTUnwrap(hits.first, "fixture message not indexed")
        _ = try await definitions.intents["OpenMessageIntent"].makeIntent(target: target).run()

        let window = app.windows["Inlet"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "opening a message must show the window")
        XCTAssertTrue(window.staticTexts["Flare"].firstMatch.waitForExistence(timeout: 5), "conversation title missing")
        // Neighbouring messages from the same chat give the context.
        XCTAssertTrue(window.staticTexts["Did you watch Dune Part Three yet?"].exists)
        XCTAssertTrue(window.staticTexts["Get me one too. Also the landlord wants the rent by the 5th."].exists)
        snap("9-conversation", window)

        let cleaner = XCUIApplication()
        cleaner.launchArguments = ["--remove-fixtures", "--offline"]
        cleaner.launch()
        _ = cleaner.wait(for: .notRunning, timeout: 20)
    }
}
