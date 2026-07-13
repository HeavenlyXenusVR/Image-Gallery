import SwiftUI

/// Lets the user override the auto-discovered backend origin — mirrors
/// Lumisound's `StreamingService.bridgeURL` Settings field, and is reachable
/// both pre-login (from the login screen) and from the main Settings tab.
struct BackendSettingsView: View {
    @State private var override = LiveConfigService.shared.manualOverride
    @State private var resolvedOrigin = LiveConfigService.shared.currentOrigin
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                Text("Currently using: \(resolvedOrigin.isEmpty ? "Not configured" : resolvedOrigin)")
                    .foregroundStyle(.secondary)
            }

            Section("Manual override") {
                TextField("http://127.0.0.1:8788", text: $override)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Leave blank to auto-discover the live backend URL. Set this to point at a local development server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }

                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text("Refresh auto-discovered URL").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Backend")
    }

    private func save() {
        LiveConfigService.shared.manualOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedOrigin = LiveConfigService.shared.currentOrigin
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        resolvedOrigin = await LiveConfigService.shared.refresh()
    }
}
