import SwiftUI

/// Presented as a sheet whenever the viewer hits 18+-gated content, or from
/// Settings. Mirrors `frontend/src/pages/SettingsPage.jsx`'s age-verification
/// form (`POST /api/me/age-verification`).
struct AgeVerificationView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var birthdate = Date(timeIntervalSince1970: 0)
    @State private var confirmOver18 = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Birthdate", selection: $birthdate, displayedComponents: .date)
                    Toggle("I am 18 years of age or older", isOn: $confirmOver18)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await verify() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Verify Age").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!confirmOver18 || isLoading)
                }
            }
            .navigationTitle("Age Verification")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func verify() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            let user = try await GalleryAPIClient.shared.verifyAge(birthdate: formatter.string(from: birthdate))
            session.setCurrentUser(user)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
