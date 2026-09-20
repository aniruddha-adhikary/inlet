import AppIntents
import SwiftUI

/// The chat a Siri or Spotlight result came from, opened at that message with its
/// neighbours. Read-only. Every row is annotated with its entity so Siri can keep
/// reasoning about what is on screen ("summarize this", "who said that?").
struct ConversationView: View {
    let model: AppModel
    let focus: AppModel.Focus
    @State private var confirmExclude = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Button { model.focus = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Hide This Chat from Siri…", role: .destructive) { confirmExclude = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title).font(.title2.bold())
                Label("\(Donor.appName(focus.appID)) · Read only", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.focusMessages, id: \.id) { message in
                            Bubble(message: message, highlighted: message.id == focus.messageID).id(message.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: focus) { scroll(proxy) }
            }
        }
        .confirmationDialog("Hide “\(focus.title)” from Siri?", isPresented: $confirmExclude) {
            Button("Hide Chat", role: .destructive) { Task { await model.exclude(focus) } }
        } message: {
            Text("What Inlet stored from this chat is deleted from this Mac and removed from Siri and Spotlight. You can show it again at any time.")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = focus.messageID ?? model.focusMessages.last?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(target, anchor: .center) } }
    }
}

private struct Bubble: View {
    let message: BridgedMessage
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.outgoing ? "You" : (message.sender ?? "Unknown")).font(.caption.weight(.semibold))
                if let date = message.sentAt {
                    Text(date, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(message.body ?? "Media message").font(.callout).textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(background, in: .rect(cornerRadius: 12))
        .overlay { if highlighted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
        .appEntityIdentifier(EntityIdentifier(for: MessageEntity.self, identifier: message.id))
    }

    private var background: some ShapeStyle {
        message.outgoing ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.6))
    }
}
