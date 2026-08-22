import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var biometricLock: BiometricLockService
    @StateObject private var viewModel = SettingsViewModel()
    @AppStorage("theme_mode") private var themeMode = "system"
    @State private var biometricLockEnabled = false
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var showingAgeVerification = false
    @State private var showingTotpEnroll = false
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var accentColor = Color(hex: Appearance.defaultAccentHex)
    // Unlike accentColor, this stays nil when unset -- an optional second
    // color, not a color with a fallback default (mirrors accent_secondary
    // being able to be cleared back to "no gradient" on web).
    @State private var accentSecondary: Color?
    @State private var profileLayout = "spotlight"
    @State private var avatarShape = AvatarShape.circle
    @State private var autoplayPreviews = false
    @State private var mutedPreviews = true
    @State private var blurVideoPreviews = false
    @State private var reduceMotion = false
    @State private var gridDensity = "comfortable"
    @State private var defaultSort = "new"
    @State private var profileShowFollowCounts = true
    @State private var profileShowJoinedDate = true
    @State private var watermarkText = ""
    @State private var discordWebhookUrl = ""
    @State private var cardAspectRatio = "free"
    @State private var mediaBorderStyle = "none"
    @State private var cardInfoDisplay = "below"
    @State private var columnGap = "normal"
    @State private var galleryFont = "system"
    @State private var profileHeaderStyle = "solid"
    @State private var openOriginalInNewTab = false
    @State private var isSavingAppearance = false
    @State private var loadedAppearance = false
    @State private var showingLogoutConfirm = false
    @State private var searchPendingDelete: SavedSearch?
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var isChangingPassword = false
    @State private var passwordMessage: String?
    @State private var discordStatus: DiscordVerifyStatus?
    @State private var discordUserId = ""
    @State private var discordCode = ""
    @State private var isDiscordBusy = false
    @State private var discordMessage: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                if let accentSecondary {
                    ColorPicker("Secondary accent", selection: Binding(get: { accentSecondary }, set: { self.accentSecondary = $0 }), supportsOpacity: false)
                    Button("Clear secondary accent", role: .destructive) { self.accentSecondary = nil }
                } else {
                    Button("Add secondary accent") { accentSecondary = accentColor }
                }
                Picker("Profile layout", selection: $profileLayout) {
                    Text("Standard").tag("spotlight")
                    Text("Grid First").tag("mosaic")
                }
                .pickerStyle(.segmented)
                Picker("Avatar shape", selection: $avatarShape) {
                    Text("Circle").tag(AvatarShape.circle)
                    Text("Rounded").tag(AvatarShape.rounded)
                    Text("Square").tag(AvatarShape.square)
                }
                .pickerStyle(.segmented)
                Picker("Grid density", selection: $gridDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Wide").tag("wide")
                }
                .pickerStyle(.segmented)
                Picker("Default sort", selection: $defaultSort) {
                    Text("New").tag("new")
                    Text("Popular").tag("popular")
                    Text("Downloads").tag("downloads")
                    Text("Views").tag("views")
                    Text("Old").tag("old")
                }
                Picker("Card aspect ratio", selection: $cardAspectRatio) {
                    Text("Free").tag("free")
                    Text("Square").tag("1:1")
                    Text("16:9").tag("16:9")
                    Text("4:3").tag("4:3")
                    Text("3:4").tag("3:4")
                }
                Picker("Card info", selection: $cardInfoDisplay) {
                    Text("Below").tag("below")
                    Text("Overlay").tag("overlay")
                    Text("Minimal").tag("minimal")
                    Text("Hidden").tag("hidden")
                }
                Picker("Card border", selection: $mediaBorderStyle) {
                    Text("None").tag("none")
                    Text("Soft").tag("soft")
                    Text("Crisp").tag("crisp")
                    Text("Glow").tag("glow")
                    Text("Neon").tag("neon")
                }
                Picker("Grid spacing", selection: $columnGap) {
                    Text("None").tag("none")
                    Text("Tight").tag("tight")
                    Text("Normal").tag("normal")
                    Text("Wide").tag("wide")
                }
                Picker("Font", selection: $galleryFont) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Monospace").tag("mono")
                    Text("Rounded").tag("rounded")
                }
                Picker("Profile header", selection: $profileHeaderStyle) {
                    Text("Solid").tag("solid")
                    Text("Glass").tag("glass")
                    Text("Blur").tag("blur")
                    Text("Transparent").tag("transparent")
                    Text("Gradient").tag("gradient")
                }
            }

            // These sections share the same "Save appearance" action as the
            // Appearance section above -- one PATCH sends the whole
            // SettingsUpdateBody, so a button per section would just be the
            // same save repeated with no independent effect. Grouped as
            // separate Form sections purely for scannability; the single
            // save button lives at the bottom of this group.
            Section("Playback & Previews") {
                Toggle("Autoplay grid previews", isOn: $autoplayPreviews)
                Toggle("Mute previews", isOn: $mutedPreviews)
                Toggle("Blur video thumbnails", isOn: $blurVideoPreviews)
                Toggle("Reduce motion", isOn: $reduceMotion)
                Toggle("Open originals in Safari", isOn: $openOriginalInNewTab)
            }

            Section("Profile Visibility") {
                Toggle("Show follow counts", isOn: $profileShowFollowCounts)
                Toggle("Show joined date", isOn: $profileShowJoinedDate)
            }

            Section("Watermark") {
                TextField("Watermark text (applied to your images)", text: $watermarkText)
                Button {
                    Task { await saveAppearance() }
                } label: {
                    if isSavingAppearance {
                        ProgressView()
                    } else {
                        Text("Save appearance").frame(maxWidth: .infinity)
                    }
                }
            }

            Section("Account") {
                HStack {
                    AvatarView(urlString: session.currentUser?.avatarUrl, fallbackInitial: String(session.currentUser?.username.prefix(1) ?? "?"), shape: avatarShape, size: 44)
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
                Toggle("Require \(biometricLock.biometryLabel) to open", isOn: $biometricLockEnabled)
                    .onChange(of: biometricLockEnabled) { newValue in
                        biometricLock.isEnabled = newValue
                    }
                Button("Log Out", role: .destructive) {
                    showingLogoutConfirm = true
                }
            }

            Section("Two-Factor Authentication") {
                if viewModel.totp?.enabled == true {
                    Text("Enabled — \(viewModel.totp?.recoveryCodesRemaining ?? 0) recovery codes remaining")
                } else {
                    Button("Enable 2FA") { showingTotpEnroll = true }
                }
            }

            Section("Change Password") {
                SecureField("Current password", text: $oldPassword)
                SecureField("New password (8+ characters)", text: $newPassword)
                if let passwordMessage {
                    Text(passwordMessage).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await changePassword() }
                } label: {
                    if isChangingPassword {
                        ProgressView()
                    } else {
                        Text("Change Password")
                    }
                }
                .disabled(isChangingPassword || oldPassword.isEmpty || newPassword.count < 8)
            }

            // Backs both "Send Code to My Webhook" right below and the
            // per-creator upload-notification digest (routes.lua's upload
            // webhook + digest.lua) -- previously configurable only from the
            // web Settings page, so that webhook button here always failed
            // silently for anyone who'd never touched the web app.
            Section("Discord Webhook") {
                TextField("https://discord.com/api/webhooks/…", text: $discordWebhookUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await saveAppearance() }
                } label: {
                    if isSavingAppearance {
                        ProgressView()
                    } else {
                        Text("Save webhook URL")
                    }
                }
            }

            Section("Discord Verification") {
                if discordStatus?.verified == true {
                    HStack {
                        Label(
                            discordStatus?.discordUsername.map { "Verified as @\($0)" } ?? "Verified",
                            systemImage: "checkmark.seal.fill"
                        )
                        Spacer()
                        Button("Unlink", role: .destructive) { Task { await unlinkDiscord() } }
                    }
                } else {
                    TextField("Discord User ID (for a DM code)", text: $discordUserId)
                        .keyboardType(.numberPad)
                    Button("Send Code via DM") { Task { await startDiscordVerify(method: "dm") } }
                        .disabled(isDiscordBusy || discordUserId.isEmpty || discordStatus?.dmAvailable == false)
                    Button("Send Code to My Webhook") { Task { await startDiscordVerify(method: "webhook") } }
                        .disabled(isDiscordBusy)
                    if let pending = discordStatus?.pending {
                        TextField("Enter code (\(pending.method == "dm" ? "sent via DM" : "posted to your webhook"))", text: $discordCode)
                        Button("Confirm") { Task { await confirmDiscordVerify() } }
                            .disabled(isDiscordBusy || discordCode.isEmpty)
                    }
                }
                if let discordMessage {
                    Text(discordMessage).font(.caption).foregroundStyle(.secondary)
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
                            searchPendingDelete = search
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete saved search \(search.name)")
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

            APIKeysSection()

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

            if let vision = viewModel.visionStatus {
                Section("AI Training") {
                    Text("Every time you correct an AI-suggested title, tags, or category on upload, that correction is saved as a training example — this is where those accumulate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Provider", value: vision.activeModel.map { "\(vision.provider) — \($0)" } ?? vision.provider)
                    LabeledContent("Status", value: visionStatusText(vision))
                    LabeledContent("Training examples", value: "\(vision.trainingExamplesAvailable)")
                    Button {
                        Task {
                            if let url = await viewModel.exportTrainingData() {
                                exportURL = url
                                showingShareSheet = true
                            }
                        }
                    } label: {
                        if viewModel.isExportingTraining {
                            ProgressView()
                        } else {
                            Text("Export training data (JSONL)")
                        }
                    }
                    .disabled(vision.trainingExamplesAvailable == 0)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await viewModel.loadAll()
            loadAppearanceFromCurrentUser()
            biometricLockEnabled = biometricLock.isEnabled
            discordStatus = try? await GalleryAPIClient.shared.discordVerifyStatus()
        }
        .onChange(of: session.currentUser?.id) { _ in
            loadAppearanceFromCurrentUser()
        }
        .sheet(isPresented: $showingAgeVerification) { AgeVerificationView() }
        .sheet(isPresented: $showingTotpEnroll) { TotpEnrollmentView() }
        .sheet(isPresented: $showingShareSheet) {
            if let exportURL {
                ShareSheet(activityItems: [exportURL])
            }
        }
        .confirmationDialog("Log out?", isPresented: $showingLogoutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                Task { await session.logout() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(searchPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { searchPendingDelete != nil },
                set: { active in if !active { searchPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let search = searchPendingDelete {
                    Task { await viewModel.deleteSavedSearch(search) }
                }
                searchPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { searchPendingDelete = nil }
        }
    }

    private func visionStatusText(_ vision: AIVisionStatus) -> String {
        guard vision.aiEnabled else { return "Disabled" }
        if vision.reachable == false { return vision.reason ?? "Unreachable" }
        return "Reachable"
    }

    /// Seeds the appearance controls from the account's stored settings —
    /// only once per login, so it doesn't stomp on in-progress edits every
    /// time `session.currentUser` gets refreshed in the background.
    private func loadAppearanceFromCurrentUser() {
        guard !loadedAppearance, let settings = session.currentUser?.userSettings else { return }
        loadedAppearance = true
        if let theme = settings.themeMode, !theme.isEmpty { themeMode = theme }
        accentColor = Color(hex: settings.accentColor)
        accentSecondary = (settings.accentSecondary?.isEmpty == false) ? Color(hex: settings.accentSecondary) : nil
        profileLayout = settings.profileLayout ?? "spotlight"
        avatarShape = AvatarShape(settings.profileAvatarShape)
        autoplayPreviews = settings.autoplayPreviews ?? false
        mutedPreviews = settings.mutedPreviews ?? true
        blurVideoPreviews = settings.blurVideoPreviews ?? false
        reduceMotion = settings.reduceMotion ?? false
        gridDensity = settings.gridDensity ?? "comfortable"
        defaultSort = settings.defaultSort ?? "new"
        profileShowFollowCounts = settings.profileShowFollowCounts ?? true
        profileShowJoinedDate = settings.profileShowJoinedDate ?? true
        watermarkText = settings.watermarkText ?? ""
        discordWebhookUrl = settings.discordWebhookUrl ?? ""
        cardAspectRatio = settings.cardAspectRatio ?? "free"
        mediaBorderStyle = settings.mediaBorderStyle ?? "none"
        cardInfoDisplay = settings.cardInfoDisplay ?? "below"
        columnGap = settings.columnGap ?? "normal"
        galleryFont = settings.galleryFont ?? "system"
        profileHeaderStyle = settings.profileHeaderStyle ?? "solid"
        openOriginalInNewTab = settings.openOriginalInNewTab ?? false
    }

    private func saveAppearance() async {
        isSavingAppearance = true
        defer { isSavingAppearance = false }
        do {
            let body = GalleryAPIClient.SettingsUpdateBody(
                themeMode: themeMode,
                accentColor: accentColor.toHexString(),
                // Always sent, never omitted -- "" is what actually clears
                // it server-side (user_settings.lua's COLOR_FIELDS handling
                // treats an explicit empty string as "no color", but omitting
                // the key entirely just leaves whatever was already stored).
                accentSecondary: accentSecondary?.toHexString() ?? "",
                profileLayout: profileLayout,
                profileAvatarShape: avatarShape.rawValue,
                autoplayPreviews: autoplayPreviews,
                mutedPreviews: mutedPreviews,
                blurVideoPreviews: blurVideoPreviews,
                reduceMotion: reduceMotion,
                gridDensity: gridDensity,
                defaultSort: defaultSort,
                profileShowFollowCounts: profileShowFollowCounts,
                profileShowJoinedDate: profileShowJoinedDate,
                watermarkText: watermarkText,
                discordWebhookUrl: discordWebhookUrl,
                cardAspectRatio: cardAspectRatio,
                mediaBorderStyle: mediaBorderStyle,
                cardInfoDisplay: cardInfoDisplay,
                columnGap: columnGap,
                galleryFont: galleryFont,
                profileHeaderStyle: profileHeaderStyle,
                openOriginalInNewTab: openOriginalInNewTab
            )
            let user = try await GalleryAPIClient.shared.updateSettings(body)
            session.setCurrentUser(user)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func uploadAvatar() async {
        guard let avatarPickerItem else { return }
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            guard let data = try await avatarPickerItem.loadTransferable(type: Data.self) else {
                viewModel.errorMessage = "Could not read that image. Try picking it again."
                return
            }
            let user = try await GalleryAPIClient.shared.uploadAvatar(data: data, fileName: "avatar.jpg", mimeType: "image/jpeg")
            session.setCurrentUser(user)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func changePassword() async {
        isChangingPassword = true
        defer { isChangingPassword = false }
        passwordMessage = nil
        do {
            try await GalleryAPIClient.shared.changePassword(oldPassword: oldPassword, newPassword: newPassword)
            oldPassword = ""
            newPassword = ""
            passwordMessage = "Password changed."
        } catch {
            passwordMessage = error.localizedDescription
        }
    }

    private func refreshDiscordStatus() async {
        discordStatus = try? await GalleryAPIClient.shared.discordVerifyStatus()
    }

    private func startDiscordVerify(method: String) async {
        isDiscordBusy = true
        defer { isDiscordBusy = false }
        discordMessage = nil
        do {
            let response = try await GalleryAPIClient.shared.discordVerifyStart(method: method, discordUserId: method == "dm" ? discordUserId : nil)
            discordMessage = "Code sent via \(response.method == "dm" ? "Discord DM" : "your Discord webhook")."
            await refreshDiscordStatus()
        } catch {
            discordMessage = error.localizedDescription
        }
    }

    private func confirmDiscordVerify() async {
        isDiscordBusy = true
        defer { isDiscordBusy = false }
        do {
            let user = try await GalleryAPIClient.shared.discordVerifyConfirm(code: discordCode)
            session.setCurrentUser(user)
            discordCode = ""
            discordMessage = "Discord verified."
            await refreshDiscordStatus()
        } catch {
            discordMessage = error.localizedDescription
        }
    }

    private func unlinkDiscord() async {
        isDiscordBusy = true
        defer { isDiscordBusy = false }
        do {
            let user = try await GalleryAPIClient.shared.discordUnlink()
            session.setCurrentUser(user)
            discordMessage = "Discord unlinked."
            await refreshDiscordStatus()
        } catch {
            discordMessage = error.localizedDescription
        }
    }
}
