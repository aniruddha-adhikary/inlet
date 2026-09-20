import SwiftUI

/// Everything the main window deliberately leaves out: counts, reader health and
/// the log. Help > Diagnostics. Shows numbers and states, never content.
struct DiagnosticsView: View {
    let model: AppModel
    @State private var log = ""
    @State private var profiles: [(key: String, status: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Index") {
                    LabeledContent("Stored", value: model.total.formatted())
                    LabeledContent("Waiting for Spotlight", value: model.pending.formatted())
                    LabeledContent("Held by Spotlight", value: model.indexed.formatted())
                    if let error = model.lastError { LabeledContent("Last error", value: error) }
                }
                Section("Apps") {
                    ForEach(model.sessions, id: \.key) { session in
                        LabeledContent(session.account.name) {
                            Text("\(String(describing: session.state)) · \((model.countsByApp[session.key] ?? 0).formatted()) stored\(session.lastIngest.map { " · last batch: " + $0 } ?? "")")
                        }
                    }
                }
                Section("Readers") {
                    ForEach(profiles, id: \.key) { profile in
                        LabeledContent(profile.key) {
                            HStack {
                                Text(profile.status)
                                if profile.status == "quarantined" {
                                    Button("Release") { try? BridgeStore.default.release(profile.key); reload() }
                                }
                            }
                        }
                    }
                }
                Section("Log") {
                    ScrollView {
                        Text(log).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            }
            .formStyle(.grouped)
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func reload() {
        profiles = BridgeStore.default.profileStates().sorted { $0.key < $1.key }
        let text = (try? String(contentsOf: AppPaths.log, encoding: .utf8)) ?? ""
        log = text.split(separator: "\n").suffix(60).joined(separator: "\n")
    }
}
