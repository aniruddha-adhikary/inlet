import AppIntents
import SwiftUI

@main
struct ChatbridgeApp: App {
    @State private var model = AppModel.shared

    init() {
        // Headless by default: syncing starts without any window.
        Task { @MainActor in AppModel.shared.start() }
    }

    var body: some Scene {
        Window("Chatbridge", id: "main") {
            SourcesView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            ForEach(model.sessions, id: \.descriptor.id) { session in
                if session.state == .connected { Text("\(session.descriptor.name) connected") }
            }
            if !model.anyConnected { Text("No apps connected") }
            Text("\(model.total) messages available to Siri")
            Divider()
            OpenMainWindowButton()
            Button("Quit Chatbridge") { NSApp.terminate(nil) }
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// Lives for the whole session, so it is where the windowless app keeps a
/// way to open its main window on demand (from Siri's "open" intents).
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .onAppear {
                model.openMainWindow = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Chatbridge") {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

struct SourcesView: View {
    let model: AppModel
    @State private var confirmErase = false

    var body: some View {
        Group {
            if let focus = model.focus {
                ConversationView(model: model, focus: focus).frame(height: 560)
            } else {
                sources
            }
        }
        .padding(28)
        .frame(width: 560)
        .confirmationDialog("Erase everything Chatbridge has stored?", isPresented: $confirmErase) {
            Button("Erase everything", role: .destructive) { Task { await model.eraseEverything() } }
        } message: {
            Text("You'll be signed out of every connected app. Stored messages are deleted, removed from Siri and Spotlight, and the encryption key is destroyed. This can't be undone.")
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chatbridge").font(.largeTitle.bold())
                Text("Let Siri search apps that haven't added support yet. Everything stays on this Mac, and Chatbridge can only read — never send.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.sessions, id: \.descriptor.id) { session in
                SourceCard(session: session, count: model.countsByApp[session.descriptor.id] ?? 0) {
                    Task { await model.remove(session) }
                }
            }

            HStack(spacing: 24) {
                Stat(value: model.total, label: "messages Siri can search")
                Stat(value: model.pending, label: "waiting to be indexed")
                Spacer()
                Button("Erase everything…", role: .destructive) { confirmErase = true }
                    .help("Signs out of every app, deletes all stored messages, removes them from Siri and Spotlight, and destroys the encryption key.")
            }

            IndexedPreview(model: model)

            if !model.exclusions.isEmpty {
                DisclosureGroup("Chats you've stopped indexing (\(model.exclusions.count))") {
                    ForEach(model.exclusions, id: \.keyHash) { item in
                        HStack {
                            Text("\(item.label) · \(Donor.appName(item.appID))").font(.callout)
                            Spacer()
                            Button("Include again") { Task { await model.include(keyHash: item.keyHash) } }.controlSize(.small)
                        }
                    }
                }
                .font(.callout)
            }

            Label("Stored on this Mac only, encrypted. Chatbridge can read your chats but never send, edit or mark anything.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }

    }
}

/// Shows the user exactly what Siri has been given. Every row is annotated
/// with the MessageEntity it represents (the App Intents view-annotation API),
/// which is what lets Siri read and reason about what's on screen natively.
private struct IndexedPreview: View {
    let model: AppModel
    @State private var query = ""
    @State private var results: [BridgedMessage]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Siri can see").font(.headline)
            HStack {
                TextField("Search bridged messages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("Search", action: run).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if results != nil { Button("Clear") { results = nil; query = "" } }
            }
            if let results {
                if results.isEmpty {
                    Text("No bridged messages match “\(query)”.").foregroundStyle(.secondary)
                } else {
                    Text("\(results.count) match\(results.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary)
                    rows(results)
                }
            } else if !model.recent.isEmpty {
                Text("Most recent").font(.caption).foregroundStyle(.secondary)
                rows(model.recent)
            }
        }
    }

    private func rows(_ messages: [BridgedMessage]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.id) { message in
                    MessageRow(message: message)
                }
            }
        }
        .frame(maxHeight: 260)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private func run() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { results = nil; return }
        let store = BridgeStore.default
        Task { results = (try? await Task.detached { try store.search(words, limit: 25) }.value) ?? [] }
    }
}

private struct MessageRow: View {
    let message: BridgedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.sender ?? "Unknown").font(.callout.weight(.semibold))
                Text(message.conversationName ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let date = message.sentAt {
                    Text(date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Text(message.body ?? "Media message").font(.callout).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appEntityIdentifier(EntityIdentifier(for: MessageEntity.self, identifier: message.id))
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(value.formatted()).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SourceCard: View {
    let session: SourceSession
    let count: Int
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.descriptor.symbol)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background((session.descriptor.tint == "blue" ? Color.blue : Color.green).gradient, in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.descriptor.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).foregroundStyle(.secondary)
                }
                if session.state == .connected {
                    Text("\(count.formatted()) messages\(session.lastIngest.map { " · last sync: " + $0 } ?? "")").font(.caption).foregroundStyle(.tertiary)
                } else if let note = session.descriptor.note {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            actions
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var actions: some View {
        switch session.state {
        case .idle, .failed:
            Button("Connect") { session.start(showWindow: true) }.buttonStyle(.borderedProminent)
        case .loading:
            ProgressView().controlSize(.small)
        case .needsLogin:
            Button("Sign in") { session.show() }.buttonStyle(.borderedProminent)
        case .connected:
            Menu("Connected") {
                Button("Show \(session.descriptor.name) window") { session.show() }
                Button("Disconnect and delete its messages", role: .destructive, action: onRemove)
            }
            .fixedSize()
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Not connected"
        case .loading: "Checking sign-in…"
        case .needsLogin: "Waiting for you to sign in"
        case .connected: "Syncing in the background"
        case .failed(let why): why
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .needsLogin, .loading: .orange
        default: .gray
        }
    }
}
