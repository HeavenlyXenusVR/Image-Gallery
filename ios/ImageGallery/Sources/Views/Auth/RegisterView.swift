import SwiftUI

struct RegisterView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showingRegister: Bool

    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Display name (optional)", text: $displayName)
                TextField("Email (optional)", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await register() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Create Account").frame(maxWidth: .infinity)
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || isLoading)

                Button("Already have an account? Log in") {
                    showingRegister = false
                }
            }
        }
    }

    private func register() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await session.register(
                username: username,
                password: password,
                email: email.isEmpty ? nil : email,
                displayName: displayName.isEmpty ? nil : displayName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
