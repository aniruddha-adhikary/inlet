import SwiftUI

/// The "Add App" sheet: a searchable grid that works the same for two apps or fifty.
struct GalleryView: View {
    let model: AppModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var apps: [AppDescriptor] {
        let all = model.availableApps
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add App").font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(16)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                    ForEach(apps) { app in
                        GalleryTile(app: app, isAdded: model.session(app.id) != nil) { model.add(app) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Label("You sign in to each app directly. Inlet can read, never send.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 360)
    }
}

private struct GalleryTile: View {
    let app: AppDescriptor
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            VStack(spacing: 6) {
                AppTile(app: app, size: 56, dimmed: !app.isAvailable)
                    .overlay(alignment: .bottomTrailing) {
                        if isAdded {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                                .offset(x: 5, y: 5)
                        }
                    }
                Text(app.name).font(.callout)
                Text(app.isAvailable ? " " : "Coming Later").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!app.isAvailable || isAdded)
        .accessibilityIdentifier("gallery-\(app.id)")
        .accessibilityLabel(app.isAvailable ? (isAdded ? "\(app.name), added" : "Add \(app.name)") : "\(app.name), coming later")
    }
}
