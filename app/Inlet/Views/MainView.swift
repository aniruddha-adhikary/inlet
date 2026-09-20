import SwiftUI

/// The one window: your apps on the left, the selected app (or Privacy) on the right.
/// Modelled on System Settings, so it behaves the way Mac users already expect.
struct MainView: View {
    @Bindable var model: AppModel
    static let privacyItem = "privacy"

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Accounts") {
                    ForEach(model.sessions, id: \.key) { session in
                        SidebarRow(app: session.descriptor, name: session.account.name, status: model.status(of: session))
                            .tag(session.key)
                    }
                }
                Section {
                    Label("Privacy", systemImage: "hand.raised.fill").tag(Self.privacyItem)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Button { model.showsGallery = true } label: { Label("Add Account", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .accessibilityIdentifier("add-app")
            }
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Inlet Help") { model.show(window: "help") }
                    SettingsLink { Text("Settings…") }
                    Button("About Inlet") { model.show(window: "about") }
                    Divider()
                    Button("Welcome to Inlet") { model.showsWelcome = true }
                    Button("Take the Tour") { model.showsTour = true }
                    Divider()
                    Button("Diagnostics") { model.showDiagnostics() }
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .menuIndicator(.hidden)
                .accessibilityIdentifier("help-menu")
            }
        }
        .sheet(isPresented: $model.showsGallery) { GalleryView(model: model) }
        .sheet(isPresented: $model.showsWelcome) {
            WelcomeView {
                AppSettings.hasSeenWelcome = true
                model.showsWelcome = false
                if model.sessions.isEmpty { model.showsGallery = true }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showsTour) {
            TourView {
                AppSettings.hasSeenTour = true
                model.showsTour = false
            }
        }
        // A menu bar app has no Dock icon or menus. While its window is open it becomes a regular Mac app.
        .capturesOpenWindow(for: model)
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    @ViewBuilder private var detail: some View {
        if let focus = model.focus {
            ConversationView(model: model, focus: focus).padding(20)
        } else if model.selection == Self.privacyItem {
            PrivacyView(model: model)
        } else if let id = model.selection, let session = model.session(id) {
            AppDetailView(model: model, session: session)
        } else {
            ContentUnavailableView {
                Label("Add Your First Account", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose an app, sign in, and Siri can find what's in it.")
            } actions: {
                Button("Add Account…") { model.showsGallery = true }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct SidebarRow: View {
    let app: AppDescriptor
    let name: String
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 8) {
            AppTile(app: app, size: 22)
            Text(name).lineLimit(1)
            Spacer()
            StatusDot(status: status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(status.label)")
    }
}

/// The app's rounded tile, used everywhere an app is shown.
struct AppTile: View {
    let app: AppDescriptor
    let size: CGFloat
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(dimmed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(app.tint.gradient))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            }
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let status: AppModel.Status

    var body: some View {
        switch status {
        case .updating: ProgressView().controlSize(.mini)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary).imageScale(.small)
        default: Circle().fill(status.color).frame(width: 8, height: 8)
        }
    }
}

extension AppModel.Status {
    var label: String {
        switch self {
        case .upToDate: "Up to date"
        case .updating: "Updating…"
        case .paused: "Paused"
        case .signInNeeded: "Sign in needed"
        case .problem: "Couldn't connect"
        }
    }

    var color: Color {
        switch self {
        case .upToDate: .green
        case .updating, .signInNeeded: .orange
        case .paused: .secondary
        case .problem: .red
        }
    }
}
