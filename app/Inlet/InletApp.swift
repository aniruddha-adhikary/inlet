import AppIntents
import SwiftUI

@main
struct InletApp: App {
    @State private var model = AppModel.shared

    init() {
        // Headless by default: reading starts without any window.
        Task { @MainActor in AppModel.shared.start() }
    }

    var body: some Scene {
        Window("Inlet", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add App…") { model.showMainWindow(); model.showsGallery = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .help) {
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

        MenuBarExtra {
            ForEach(model.sessions.filter { model.status(of: $0).needsUser }, id: \.descriptor.id) { session in
                Button("Sign In to \(session.descriptor.name)…") { session.start(showWindow: true) }
            }
            if model.needsAttention { Divider() }
            Button("Open Inlet") { model.showMainWindow() }
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
            .onAppear {
                model.openWindow = { id in
                    openWindow(id: id)
                    NSApp.activate()
                }
            }
    }
}
