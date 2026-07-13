import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showingRegister: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingTwoFactorToken: String?

    var body: some View {
        if let pendingTwoFactorToken {
            TwoFactorView(pendingToken: pendingTwoFactorToken) {
                self.pendingTwoFactorToken = nil
            }
        } else {
            loginForm
        }
    }

    private var loginForm: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await login() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Log In").frame(maxWidth: .infinity)
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || isLoading)

                Button("Need an account? Register") {
                    showingRegister = true
                }
            }

            Section {
                NavigationLink("Backend settings") {
                    BackendSettingsView()
                }
            }
        }
    }

    private func login() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await session.login(username: username, password: password)
            if response.needs2fa == true, let token = response.pendingToken {
                pendingTwoFactorToken = token
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
