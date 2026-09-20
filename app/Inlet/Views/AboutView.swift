import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Inlet").font(.title.weight(.bold))
            Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Lets Siri and Spotlight find what's inside your apps.\nOn this Mac, read only.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Divider().padding(.vertical, 6)

            VStack(spacing: 4) {
                Text("Made by Aniruddha Adhikary")
                Link("adhikary.net", destination: URL(string: "https://adhikary.net")!)
            }
            Text("Open source, under the MIT License.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Not affiliated with Apple or with the makers of the apps you add.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 360)
    }
}
