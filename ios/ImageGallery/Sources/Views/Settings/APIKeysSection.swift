import SwiftUI
import UIKit

/// Scoped, read-only API keys for personal scripts/integrations (e.g. a
/// personal RSS feed at /feed/me.xml?key=...) -- never grants write access
/// or the real login session. Mirrors the web app's API Keys box in
/// Settings. Self-contained (own state/fetch), kept as its own file/struct
/// rather than inlined into SettingsView's already-large Form body, both to
/// avoid growing that Form past a comfortable Section count and to keep
/// this feature's state next to its own view.
struct APIKeysSection: View {
    @State private var keys: [APIKey] = []
    @State private var label = ""
    @State private var isCreating = false
    @State private var newKey: String?
    @State private var errorMessage: String?

    var body: some View {
        Section("API Keys") {
            Text("Scoped, read-only keys for your own scripts/bots. Never grants write access or your login session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let newKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy this now — it won't be shown again.").font(.caption.weight(.semibold))
                    Text(newKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Copy") {
                            UIPasteboard.general.string = newKey
                        }
                        Button("Done") { self.newKey = nil }
                    }
                }
            }

            ForEach(keys) { key in
                HStack {
                    VStack(alignment: .leading) {
                        Text(key.label)
                        if key.revokedAt != nil {
                            Text("Revoked").font(.caption).foregroundStyle(.secondary)
                        } else if let lastUsedAt = key.lastUsedAt {
                            Text("Last used \(lastUsedAt.prefix(10))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Never used").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if key.revokedAt == nil {
                        Button(role: .destructive) {
                            Task { await revoke(key) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            HStack {
                TextField("Label (e.g. My RSS reader)", text: $label)
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView() } else { Text("New key") }
                }
                .disabled(isCreating)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await load() }
    }

    private func load() async {
        keys = (try? await GalleryAPIClient.shared.apiKeys()) ?? []
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let response = try await GalleryAPIClient.shared.createAPIKey(label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            newKey = response.key
            label = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ key: APIKey) async {
        do {
            try await GalleryAPIClient.shared.revokeAPIKey(id: key.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
