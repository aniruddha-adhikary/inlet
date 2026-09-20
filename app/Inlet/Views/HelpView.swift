import SwiftUI

/// Inlet Help: short, task-shaped topics. Opened from the Help menu or the "?" button.
struct HelpView: View {
    @State private var selection: String? = HelpTopic.all.first?.id

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.all, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            if let topic = HelpTopic.all.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(topic.title, systemImage: topic.symbol).font(.title2.weight(.bold))
                        ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let paragraphs: [String]

    static let all: [HelpTopic] = [
        HelpTopic(id: "start", title: "Get Started", symbol: "sparkles", paragraphs: [
            "Inlet lets Siri and Spotlight find what's inside apps that don't share their content with your Mac.",
            "**1.** Click **Add Account** and choose an app.",
            "**2.** Sign in, the same way you would in a browser. You're signing in to the app directly. Inlet never sees your password.",
            "**3.** The sign-in window closes by itself. Inlet keeps reading in the background, and what it reads becomes available to Siri and Spotlight within a few minutes.",
            "You can close the Inlet window at any time. Inlet keeps working from the menu bar.",
        ]),
        HelpTopic(id: "accounts", title: "Use More Than One Account", symbol: "person.2", paragraphs: [
            "Add as many accounts as you like for the same app, for example a work and a personal WhatsApp. Choose **Add Account** again and pick the same app.",
            "Each account has its own separate sign-in, its own stored items, and its own settings. Removing one never touches another.",
            "Give each account a **Name**. Siri uses it, so an answer can say it came from “WhatsApp Work”.",
        ]),
        HelpTopic(id: "siri", title: "Ask Siri", symbol: "apple.intelligence", paragraphs: [
            "Ask the way you'd ask a person: *“Who mentioned the recipe?”* or *“What did Mira say about Friday?”*",
            "To search only what Inlet brought in, say *“Search Inlet”* or *“Find messages in Inlet”*.",
            "Click a result to open it in Inlet, with what was said around it.",
            "Siri with Apple Intelligence on macOS 27 or later is required.",
        ]),
        HelpTopic(id: "spotlight", title: "Search with Spotlight", symbol: "magnifyingglass", paragraphs: [
            "Press **⌘ Space** and type. Items from your accounts appear alongside everything else on your Mac.",
            "If nothing appears, check that Inlet is turned on in **System Settings > Spotlight**.",
        ]),
        HelpTopic(id: "control", title: "Choose What Siri Can See", symbol: "eye.slash", paragraphs: [
            "**Pause an account.** Turn off **Available to Siri and Spotlight**. Inlet stops reading the account and Siri loses what it contributed. You stay signed in, and turning it back on restores everything.",
            "**Hide one chat.** Open any item from that chat, click the **•••** button, and choose **Hide This Chat from Siri**. What Inlet stored from it is deleted, and new items in it are ignored. Show it again from **Hidden Chats** in the account's pane.",
            "**Keep less.** Set **Keep** to One Year or 30 Days. Older items are deleted from this Mac and from Siri.",
        ]),
        HelpTopic(id: "privacy", title: "Privacy and Your Data", symbol: "hand.raised", paragraphs: [
            "**Stays on this Mac.** Inlet has no account, no server, and no analytics. Nothing it reads is uploaded anywhere.",
            "**Read only.** Inlet can't send, edit, delete, or mark anything as read in your apps.",
            "**Encrypted.** Stored items are encrypted with a key kept in your Mac's keychain, and are left out of backups.",
            "**See it.** **Privacy > See What's Stored** shows exactly what Inlet holds.",
            "**Erase it.** **Remove Account** deletes everything from one account. **Privacy > Erase All Data** signs you out everywhere, deletes everything, and destroys the encryption key.",
        ]),
        HelpTopic(id: "trouble", title: "If Something Isn't Working", symbol: "wrench.and.screwdriver", paragraphs: [
            "**An account says “Sign in needed”.** Services sign linked devices out from time to time. Select the account and click **Sign In**.",
            "**Siri can't find something.** New items can take a few minutes to become searchable. Check that the account is turned on and says “Up to date”.",
            "**An account stopped updating.** When an app changes how it works, Inlet stops reading it rather than risk storing something wrong. An update to Inlet fixes this.",
            "**The menu bar icon is hidden.** Open Inlet from Spotlight or the Applications folder. You can show the icon again in **Inlet > Settings**.",
            "For details to include in a bug report, choose **Help > Diagnostics**. It shows counts and states, never your content.",
        ]),
    ]
}
