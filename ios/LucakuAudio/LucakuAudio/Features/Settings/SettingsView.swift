import SwiftUI

/// Settings tab — GET /api/auth/me (real account info) plus a sign-out
/// action. The backend's own Settings CRUD (voice/style/delivery
/// time/length — PATCH /api/profile) and Account & data (export/delete) are
/// real endpoints too, but are left as a follow-up: this scaffold's job is
/// proving one full vertical slice (auth -> Home -> Library) end to end, not
/// wiring every existing route into a screen.
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var me: MeResponse?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if isLoading {
                        ProgressView()
                    } else if let me {
                        LabeledContent("Name", value: me.nombre)
                        LabeledContent("Email", value: me.email)
                        LabeledContent("Sign-in method", value: me.authProvider)
                        LabeledContent("Language", value: me.idioma)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section("Coming later (needs the product owner's own accounts/credentials — see ios/LucakuAudio/README.md)") {
                    LabeledContent("Google Sign-In", value: "Not wired up")
                    LabeledContent("Push notifications", value: "Not wired up")
                    LabeledContent("Membership", value: "Coming soon")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await load() }
        }
    }

    private func load() async {
        guard let token = session.accessToken else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            me = try await APIClient.shared.me(token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signOut() async {
        if let token = session.accessToken {
            try? await APIClient.shared.logout(token: token)
        }
        session.clear()
    }
}

#Preview {
    SettingsView()
        .environmentObject(SessionStore())
}
