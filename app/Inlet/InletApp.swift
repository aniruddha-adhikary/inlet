import AppIntents
import SwiftUI

@main
struct InletApp: App {
    @State private var model = AppModel.shared
    @AppStorage("settings.hideMenuBarIcon") private var hidesMenuBarIcon = false

    init() {
        // Headless by default: reading starts without any window.
        Task { @MainActor in AppModel.shared.start() }
    }

    /// Writes only real changes: an unconditional write re-invalidates the scene, which sets it again, forever.
    private var menuBarIconIsShown: Binding<Bool> {
        Binding(get: { !hidesMenuBarIcon }, set: { shown in if hidesMenuBarIcon == shown { hidesMenuBarIcon = !shown } })
    }

    var body: some Scene {
        Window("Inlet", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Inlet") { model.show(window: "about") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Account…") { model.showMainWindow(); model.showsGallery = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .help) {
                Button("Inlet Help") { model.show(window: "help") }
                    .keyboardShortcut("?")
                Divider()
                Button("Welcome to Inlet") { model.showMainWindow(); model.showsWelcome = true }
                Button("Take the Tour") { model.showMainWindow(); model.showsTour = true }
                Divider()
                Button("Diagnostics") { model.showDiagnostics() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
        .defaultSize(width: 620, height: 480)
        .defaultLaunchBehavior(.suppressed)

        Window("Inlet Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.suppressed)

        Window("About Inlet", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: menuBarIconIsShown) {
            ForEach(model.sessions.filter { model.status(of: $0).needsUser }, id: \.key) { session in
                Button("Sign In to \(session.account.name)…") { session.start(showWindow: true) }
            }
            if model.needsAttention { Divider() }
            Button("Open Inlet") { model.showMainWindow() }
            SettingsLink { Text("Settings…") }
            if NSEvent.modifierFlags.contains(.option) {
                Button("Diagnostics") { model.showDiagnostics() }
            }
            Divider()
            Button("Quit Inlet") { NSApp.terminate(nil) }
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

extension MenuBarLabel {
    /// The tray symbol with a badge in its top-right corner. Same canvas as the plain symbol,
    /// so the menu bar aligns it exactly like the unbadged one.
    static let badgedIcon: NSImage = {
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) ?? NSImage()
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: size))
            let dot = NSRect(x: size.width - 6.5, y: size.height - 6.5, width: 6.5, height: 6.5)
            // Punch a ring out of the symbol so the badge reads at menu bar size.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let symbolName = "tray.and.arrow.down.fill"
}

/// Lives for the whole session, so it is where the windowless app keeps a
/// way to open its windows on demand (from Siri's "open" intents).
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Always Inlet's own mark. When an app needs you, it gains a small badge; the menu says why.
        Group {
            if model.needsAttention { Image(nsImage: Self.badgedIcon) } else { Image(systemName: Self.symbolName) }
        }
            .accessibilityLabel(model.needsAttention ? "Inlet needs your attention" : "Inlet")
            .capturesOpenWindow(for: model)
    }
}

extension View {
    /// Hands the model SwiftUI's way of opening windows. Applied to every long-lived view,
    /// because the menu bar item (the usual carrier) can be hidden in Settings.
    func capturesOpenWindow(for model: AppModel) -> some View { modifier(OpenWindowCapture(model: model)) }
}

private struct OpenWindowCapture: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.openWindow = { id in
                openWindow(id: id)
                NSApp.activate()
            }
        }
    }
}
