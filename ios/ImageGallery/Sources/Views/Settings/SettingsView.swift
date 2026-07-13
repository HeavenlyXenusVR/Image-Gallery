import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = SettingsViewModel()
    @AppStorage("theme_mode") private var themeMode = "system"
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var showingAgeVerification = false
    @State private var showingTotpEnroll = false
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }

            Section("Account") {
                HStack {
                    avatarPreview
                    PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                        if isUploadingAvatar {
                            ProgressView()
                        } else {
                            Text("Change avatar")
                        }
                    }
                    .onChange(of: avatarPickerItem) { _ in
                        Task { await uploadAvatar() }
                    }
                }
                if session.currentUser?.ageVerifiedAt == nil {
                    Button("Verify Age (18+)") { showingAgeVerification = true }
                } else {
                    Label("Age verified", systemImage: "checkmark.seal.fill")
                }
                NavigationLink("Backend") { BackendSettingsView() }
                Button("Log Out", role: .destructive) {
                    Task { await session.logout() }
                }
            }

            Section("Two-Factor Authentication") {
                if viewModel.totp?.enabled == true {
                    Text("Enabled — \(viewModel.totp?.recoveryCodesRemaining ?? 0) recovery codes remaining")
                } else {
                    Button("Enable 2FA") { showingTotpEnroll = true }
                }
            }

            Section("Saved Searches") {
                if viewModel.savedSearches.isEmpty {
                    Text("No saved searches yet").foregroundStyle(.secondary)
                }
                ForEach(viewModel.savedSearches) { search in
                    HStack {
                        Text(search.name)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await viewModel.deleteSavedSearch(search) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Section("Blocked & Muted") {
                if viewModel.blocks.isEmpty {
                    Text("No blocked or muted accounts").foregroundStyle(.secondary)
                }
                ForEach(viewModel.blocks) { entry in
                    HStack {
                        Text(entry.user.displayName ?? entry.user.username)
                        Text(entry.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { Task { await viewModel.unblock(entry) } }
                    }
                }
            }

            Section("Your Data") {
                Button {
                    Task {
                        if let url = await viewModel.exportData() {
                            exportURL = url
                            showingShareSheet = true
                        }
                    }
                } label: {
                    if viewModel.isExporting {
                        ProgressView()
                    } else {
                        Text("Download my data")
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .task { await viewModel.loadAll() }
        .sheet(isPresented: $showingAgeVerification) { AgeVerificationView() }
        .sheet(isPresented: $showingTotpEnroll) { TotpEnrollmentView() }
        .sheet(isPresented: $showingShareSheet) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let urlString = session.currentUser?.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(.secondary.opacity(0.2))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 44, height: 44)
        }
    }

    private func uploadAvatar() async {
        guard let avatarPickerItem, let data = try? await avatarPickerItem.loadTransferable(type: Data.self) else { return }
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            let user = try await GalleryAPIClient.shared.uploadAvatar(data: data, fileName: "avatar.jpg", mimeType: "image/jpeg")
            session.setCurrentUser(user)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
