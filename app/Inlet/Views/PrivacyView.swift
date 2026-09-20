import AppIntents
import SwiftUI

/// The permanent home of the privacy promise: a picture of where data goes,
/// a way to see exactly what is stored, and one button that erases it all.
struct PrivacyView: View {
    let model: AppModel
    @State private var confirmErase = false
    @State private var showsStored = false

    var body: some View {
        Form {
            Section {
                DataFlowPicture().frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            Section {
                PrivacyPoints().padding(.vertical, 6)
            }
            Section {
                HStack {
                    Button("See What's Stored…") { showsStored = true }
                    Spacer()
                    Button("Erase All Data…", role: .destructive) { confirmErase = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsStored) { StoredItemsView(model: model) }
        .confirmationDialog("Erase everything Inlet has stored?", isPresented: $confirmErase) {
            Button("Erase All Data", role: .destructive) { Task { await model.eraseEverything() } }
        } message: {
            Text("You'll be signed out of every app in Inlet. Everything stored is deleted from this Mac and removed from Siri and Spotlight, and the encryption key is destroyed. This can't be undone.")
        }
    }
}

/// Your apps, then this Mac, then Siri.
private struct DataFlowPicture: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                stop("square.grid.2x2.fill", "Your Apps")
                arrow
                stop("laptopcomputer", "This Mac")
                arrow
                stop("apple.intelligence", "Siri")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Content goes from your apps to this Mac, then to Siri.")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
    }

    private func stop(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
            Text(title).font(.callout)
        }
    }
}

/// Transparency: browse and search exactly what Inlet holds. Rows are annotated
/// with their entity, so Siri can reason about what is on screen.
private struct StoredItemsView: View {
    let model: AppModel
    @State private var query = ""
    @State private var items: [BridgedMessage] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit(load)
            List(items, id: \.id) { item in
                Button { dismiss(); Task { await model.reveal(messageID: item.id) } } label: { StoredRow(item: item) }
                    .buttonStyle(.plain)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Nothing Stored" : "No Results", systemImage: "tray")
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
        .task { load() }
        .onChange(of: query) { if query.isEmpty { load() } }
    }

    private func load() {
        let words = query.trimmingCharacters(in: .whitespaces)
        let store = BridgeStore.default
        Task {
            items = (try? await Task.detached {
                words.isEmpty ? try store.recentlyDonated(limit: 40) : try store.search(words, limit: 40)
            }.value) ?? []
        }
    }
}

private struct StoredRow: View {
    let item: BridgedMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let app = AppCatalog.shared.app(item.appID) { AppTile(app: app, size: 22) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.outgoing ? "You" : (item.sender ?? "Unknown")).font(.callout.weight(.semibold))
                    Text(item.conversationName ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let date = item.sentAt {
                        Text(date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(item.body ?? "Attachment").font(.callout).lineLimit(2)
            }
        }
        .contentShape(.rect)
        .appEntityIdentifier(EntityIdentifier(for: MessageEntity.self, identifier: item.id))
    }
}
