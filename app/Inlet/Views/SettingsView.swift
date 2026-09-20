import ServiceManagement
import SwiftUI

/// Inlet > Settings (⌘,). App-wide choices only; everything about one account lives in its own pane.
struct SettingsView: View {
    let model: AppModel
    @AppStorage("settings.hideMenuBarIcon") private var hidesMenuBarIcon = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Show Inlet in the menu bar", isOn: Binding(get: { !hidesMenuBarIcon }, set: { hidesMenuBarIcon = !$0 }))
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                            DebugLog.write("login item: \(error)")
                            opensAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } footer: {
                Text(hidesMenuBarIcon
                     ? "Inlet keeps working in the background. Open it from Spotlight or the Applications folder."
                     : "Inlet works in the background. The menu bar icon tells you when an account needs you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Introduction") {
                    HStack {
                        Button("Welcome") { model.showMainWindow(); model.showsWelcome = true }
                        Button("Tour") { model.showMainWindow(); model.showsTour = true }
                    }
                }
                LabeledContent("Troubleshooting") {
                    Button("Open Diagnostics") { model.showDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
