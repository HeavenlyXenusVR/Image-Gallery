import SwiftUI

/// The one piece of "manage my own profile" the iOS app never had at all --
/// mirrors the web app's profile-editing fields in SettingsPage.jsx/
/// ProfilePage.jsx. `/api/me/profile` (see GalleryAPIClient.updateProfile)
/// has no partial-update semantics: every field gets written on every call,
/// and an omitted boolean defaults to `true` server-side (`clean_profile_
/// updates` in user_settings.lua) -- so this loads every field from the
/// current user up front and always sends all of them back, never just the
/// ones actually shown as editable controls here.
struct EditProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    @State private var profileQuote = ""
    @State private var websiteUrl = ""
    @State private var locationLabel = ""
    @State private var profileHeadline = ""
    @State private var featuredTagsText = ""
    @State private var profileColor = Color(hex: Appearance.defaultAccentHex)
    @State private var publicProfile = true
    @State private var showLikedCount = true
    @State private var showCollections = true
    @State private var showRecentUploads = true
    @State private var showFriends = true

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("About") {
                TextField("Display name", text: $displayName)
                TextField("Headline", text: $profileHeadline)
                TextField("Quote", text: $profileQuote)
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Links") {
                TextField("Website (https://…)", text: $websiteUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Location", text: $locationLabel)
            }

            Section("Featured Tags") {
                TagChipsField(tags: $featuredTagsText)
            }

            Section("Profile Color") {
                ColorPicker("Accent color", selection: $profileColor, supportsOpacity: false)
            }

            Section("Visibility") {
                Toggle("Public profile", isOn: $publicProfile)
                Toggle("Show liked count", isOn: $showLikedCount)
                Toggle("Show collections", isOn: $showCollections)
                Toggle("Show recent uploads", isOn: $showRecentUploads)
                Toggle("Show friends", isOn: $showFriends)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Edit Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isSaving || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { loadFromCurrentUser() }
    }

    private func loadFromCurrentUser() {
        guard !loaded, let user = session.currentUser else { return }
        loaded = true
        displayName = user.displayName ?? user.username
        bio = user.bio ?? ""
        profileQuote = user.profileQuote ?? ""
        websiteUrl = user.websiteUrl ?? ""
        locationLabel = user.locationLabel ?? ""
        profileHeadline = user.profileHeadline ?? ""
        featuredTagsText = (user.featuredTags ?? []).joined(separator: ", ")
        profileColor = Color(hex: user.profileColor)
        publicProfile = user.publicProfile ?? true
        showLikedCount = user.showLikedCount ?? true
        showCollections = user.showCollections ?? true
        showRecentUploads = user.showRecentUploads ?? true
        showFriends = user.showFriends ?? true
    }

    private func save() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let tags = featuredTagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = GalleryAPIClient.UpdateProfileBody(
            displayName: trimmedName,
            bio: bio.nilIfEmpty,
            profileQuote: profileQuote.nilIfEmpty,
            websiteUrl: websiteUrl.nilIfEmpty,
            locationLabel: locationLabel.nilIfEmpty,
            profileHeadline: profileHeadline.nilIfEmpty,
            featuredTags: tags,
            profileColor: profileColor.toHexString(),
            publicProfile: publicProfile,
            showLikedCount: showLikedCount,
            showCollections: showCollections,
            showRecentUploads: showRecentUploads,
            showFriends: showFriends
        )
        do {
            let user = try await GalleryAPIClient.shared.updateProfile(body)
            session.setCurrentUser(user)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
