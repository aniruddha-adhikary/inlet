import SwiftUI

/// Three pictures, shown once after the first app is ready. Help > Take the Tour replays it.
struct TourView: View {
    let onDone: () -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let example: String?
        let body: String
    }

    private let pages = [
        Page(symbol: "apple.intelligence", title: "Ask Siri",
             example: "Who mentioned the recipe?", body: "Ask the way you'd ask a friend. Siri answers from the apps you added."),
        Page(symbol: "magnifyingglass", title: "Search with Spotlight",
             example: "recipe", body: "Press ⌘ Space and type. Results from your apps appear with everything else."),
        Page(symbol: "text.bubble", title: "See It in Context",
             example: nil, body: "Click a result to see what was said around it. You can hide any chat from Siri there."),
    ]

    var body: some View {
        let current = pages[page]
        VStack(spacing: 18) {
            Image(systemName: current.symbol)
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.tint)
                .frame(height: 96)
                .accessibilityHidden(true)
            Text(current.title).font(.title.weight(.bold))
            if let example = current.example {
                Text("“\(example)”")
                    .font(.title3)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.quaternary, in: .capsule)
            }
            Text(current.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            HStack {
                Button("Skip", action: onDone).buttonStyle(.borderless).opacity(page == pages.count - 1 ? 0 : 1)
                Spacer()
                if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                Button(page == pages.count - 1 ? "Done" : "Next") {
                    if page == pages.count - 1 { onDone() } else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 460, height: 400)
    }
}
