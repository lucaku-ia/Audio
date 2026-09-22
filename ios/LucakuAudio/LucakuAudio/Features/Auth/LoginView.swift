import SwiftUI

/// Plain, unstyled email+password login — matches the one auth method the
/// backend actually implements (backend/app/api/routes/auth.py: "Google and
/// Apple are out of scope for this first cut"). Shown whenever there's no
/// stored session; on success it stores the token and the rest of the app
/// (TabView) takes over.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nombre = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable {
        case login = "Log In"
        case signup = "Sign Up"
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Section {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    if mode == .signup {
                        TextField("Name", text: $nombre)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Lucaku Audio")
        }
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let token: TokenResponse
            switch mode {
            case .login:
                token = try await APIClient.shared.login(email: email, password: password)
            case .signup:
                // Device locale, not hardcoded — Cliente.idioma is captured
                // once here and inherited everywhere else (onboarding
                // labels/suggestions, the Generator's script language).
                let idioma = Locale.current.language.languageCode?.identifier == "es" ? "es" : "en"
                token = try await APIClient.shared.signup(
                    SignupRequest(email: email, password: password, nombre: nombre.isEmpty ? email : nombre, idioma: idioma)
                )
            }
            session.store(token: token.accessToken, onboardingComplete: token.onboardingComplete)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(SessionStore())
}
