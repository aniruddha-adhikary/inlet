import SwiftUI

/// First launch, before any sign-in: what Inlet does with your data, in three lines.
struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage) // straight from the bundle: the system icon cache can lag
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Welcome to Inlet").font(.largeTitle.weight(.bold))
            Text("Siri can find what's in the apps you add.")
                .font(.title3).foregroundStyle(.secondary)

            PrivacyPoints().padding(.vertical, 6)

            Button(action: onContinue) { Text("Continue").frame(width: 180) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(width: 520)
    }
}

/// The three promises. Shown at welcome and again, permanently, in Privacy.
struct PrivacyPoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            point("laptopcomputer", "Stays on This Mac", "Nothing is uploaded. There is no account and no server.")
            point("eye", "Read Only", "Inlet can't send, edit, or delete anything in your apps.")
            point("lock.fill", "Encrypted, and Yours to Erase", "Remove an app and everything from it goes too.")
        }
    }

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
