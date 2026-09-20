import SwiftUI

/// Everything the user can decide about one app, and nothing else.
struct AppDetailView: View {
    let model: AppModel
    let session: SourceSession
    @State private var confirmRemove = false
    @State private var showsHidden = false
    @State private var name = ""

    private var app: AppDescriptor { session.descriptor }
    private var status: AppModel.Status { model.status(of: session) }
    private var hidden: [(keyHash: String, appID: String, label: String)] { model.exclusions.filter { $0.appID == session.key } }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppTile(app: app, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.account.name).font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            StatusDot(status: status)
                            Text(status.label).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if status.needsUser {
                        Button("Sign In…") { session.start(showWindow: true) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                TextField("Name", text: $name, prompt: Text(app.name))
                    .onSubmit { Task { await model.rename(session, to: name) } }
                    .accessibilityIdentifier("account-name")
            } footer: {
                Text("Siri uses this name, so you can tell your \(app.name) accounts apart.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Available to Siri and Spotlight", isOn: Binding(
                    get: { status != .paused },
                    set: { on in Task { await model.setAvailable(on, for: session) } }))
                Picker("Keep \(app.kind.itemNoun)", selection: Binding(
                    get: { _ = model.settingsRevision; return AppSettings.keepDays(session.key) },
                    set: { days in Task { await model.setKeepDays(days, for: session) } })) {
                    Text("Forever").tag(0)
                    Text("One Year").tag(365)
                    Text("30 Days").tag(30)
                }
                if !hidden.isEmpty {
                    LabeledContent("Hidden \(app.kind.containerNoun)") {
                        Button("\(hidden.count)") { showsHidden = true }.buttonStyle(.link)
                    }
                }
            } footer: {
                Label("Read only. Stored on this Mac, encrypted.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if status == .upToDate {
                        Button("Show \(app.name)…") { session.show() }
                    }
                    Spacer()
                    Button("Remove Account…", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = session.account.name }
        .onChange(of: session.key) { name = session.account.name }
        .confirmationDialog("Remove “\(session.account.name)”?", isPresented: $confirmRemove) {
            Button("Remove and Delete", role: .destructive) { Task { await model.remove(session) } }
        } message: {
            Text("You'll be signed out of this \(app.name) account in Inlet. Everything from it is deleted from this Mac and removed from Siri and Spotlight. Your other accounts aren't affected.")
        }
        .sheet(isPresented: $showsHidden) {
            HiddenItemsView(model: model, key: session.key)
        }
    }
}

private struct HiddenItemsView: View {
    let model: AppModel
    let key: String
    @Environment(\.dismiss) private var dismiss

    private var hidden: [(keyHash: String, appID: String, label: String)] { model.exclusions.filter { $0.appID == key } }

    var body: some View {
        VStack(spacing: 0) {
            List(hidden, id: \.keyHash) { item in
                HStack {
                    Label(item.label, systemImage: "eye.slash")
                    Spacer()
                    Button("Show Again") { Task { await model.include(keyHash: item.keyHash) } }
                }
            }
            Divider()
            HStack {
                Text("Siri can't see these.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
        .onChange(of: hidden.count) { if hidden.isEmpty { dismiss() } }
    }
}
