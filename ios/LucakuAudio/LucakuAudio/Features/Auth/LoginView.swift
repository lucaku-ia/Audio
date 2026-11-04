import SwiftUI

/// Sign in / Create account (screens spec 1.1–1.5).
///
/// One screen, two modes behind a segmented control. Signing in stores the
/// token and `ContentView` routes to onboarding or the tab bar from there.
/// Google and Apple are visual only until OAuth client IDs exist; "Forgot
/// password?" has no backend endpoint yet, so it confirms locally.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nombre = ""
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var credentialsError = false
    @State private var errorMessage: String?
    @State private var notice: String?

    @FocusState private var focusedField: Field?

    private enum Field { case name, email, password }

    enum Mode: String, CaseIterable {
        case login = "Sign in"
        case signup = "Create account"
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (mode == .login || !nombre.isEmpty) && !isLoading
    }

    var body: some View {
        ScrollView {
            StatusBarFadeAnchor()
            VStack(alignment: .leading, spacing: 0) {
                Wordmark()
                    .padding(.top, LucakuSpacing.sp12)

                Text("Your news, told your way.")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LucakuSpacing.sp5)

                promisesCard
                    .padding(.top, LucakuSpacing.sp5)

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, LucakuSpacing.sp5)
                .onChange(of: mode) { _, _ in
                    credentialsError = false
                    errorMessage = nil
                    notice = nil
                }

                fields
                    .padding(.top, LucakuSpacing.sp4)

                if let message = errorMessage {
                    Text(message)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.destructive)
                        .padding(.top, LucakuSpacing.sp3)
                } else if let notice {
                    Text(notice)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .padding(.top, LucakuSpacing.sp3)
                }

                if mode == .login {
                    Button("Forgot password?") { forgotPassword() }
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                }

                primaryButton
                    .padding(.top, mode == .login ? LucakuSpacing.sp1 : LucakuSpacing.sp4)

                orDivider
                    .padding(.vertical, LucakuSpacing.sp4)

                VStack(spacing: LucakuSpacing.sp2) {
                    providerButton(title: "Continue with Google", message: "Sign in with Google is coming soon") {
                        Image("GoogleGLogo").resizable().renderingMode(.original).scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                    providerButton(title: "Continue with Apple", message: "Sign in with Apple is coming soon") {
                        Image(systemName: "apple.logo").font(.system(size: 18))
                            .foregroundStyle(LucakuColor.textPrimary)
                    }
                }

                Text(mode == .signup
                     ? "By creating an account you agree to the Terms and Privacy Policy. Your topics are never sold or shared."
                     : "New here? Switch to Create account above.")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, LucakuSpacing.sp4)
                    .padding(.bottom, LucakuSpacing.sp12)
            }
            .padding(.horizontal, LucakuSpacing.sp6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            RadialGradient(colors: [LucakuColor.accentTint, .clear],
                           center: .top, startRadius: 0, endRadius: 320)
                .frame(height: 320)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .statusBarFade()
    }

    // MARK: - Promises card

    private var promisesCard: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp4) {
            promiseRow(icon: "heart.text.square",
                       title: "Only the things you follow",
                       detail: "World Cup · Champions League · Amazon stock · AI startups")
            promiseRow(icon: "slider.horizontal.3",
                       title: "Short or in depth, you decide",
                       detail: "Plain or with the numbers, calm or upbeat. It learns from what you rate.")
            promiseRow(icon: "sunrise",
                       title: "Ready every day, when you want it",
                       detail: "Morning or evening, an audio episode made for you, plus the stories to read.")
        }
        .padding(LucakuSpacing.sp4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous).fill(LucakuColor.surface))
    }

    private func promiseRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LucakuColor.icon)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LucakuColor.iconTile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LucakuTypography.subhead.weight(.semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                Text(detail)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            if mode == .signup {
                field(icon: "person", invalid: false) {
                    TextField("Your name", text: $nombre)
                        .textContentType(.name)
                        .focused($focusedField, equals: .name)
                }
            }
            field(icon: "envelope", invalid: credentialsError) {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focusedField, equals: .email)
            }
            field(icon: "lock", invalid: credentialsError) {
                HStack {
                    Group {
                        if showPassword {
                            TextField(passwordPlaceholder, text: $password)
                        } else {
                            SecureField(passwordPlaceholder, text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(mode == .signup ? .newPassword : .password)
                    .focused($focusedField, equals: .password)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(LucakuColor.textTertiary)
                    }
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
            }
        }
    }

    private var passwordPlaceholder: String {
        mode == .signup ? "Password (8+ characters)" : "Password"
    }

    private func field<Content: View>(icon: String, invalid: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Image(systemName: icon)
                .foregroundStyle(LucakuColor.textTertiary)
                .frame(width: 20)
            content()
                .font(LucakuTypography.body)
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LucakuColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(invalid ? LucakuColor.destructive : .clear, lineWidth: 1.5)
                )
        )
    }

    // MARK: - Actions

    /// Primary action: solid text colour on background (white on black in
    /// dark, black on white in light) per the brand rule.
    private var primaryButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(LucakuColor.bg)
                } else {
                    Text(mode.rawValue).font(LucakuTypography.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(LucakuColor.bg)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LucakuColor.textPrimary))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.35)
    }

    private var orDivider: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            Text("or").font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textTertiary)
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
        }
    }

    private func providerButton<Icon: View>(title: String, message: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            credentialsError = false
            errorMessage = nil
            notice = message
        } label: {
            HStack(spacing: 10) {
                icon()
                Text(title)
                    .font(LucakuTypography.body.weight(.medium))
                    .foregroundStyle(LucakuColor.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LucakuColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(LucakuColor.borderSoft, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private func forgotPassword() {
        credentialsError = false
        if email.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = nil
            notice = "Enter your email first, then tap Forgot password?"
            focusedField = .email
        } else {
            errorMessage = nil
            notice = "Reset link sent to \(email)"
        }
    }

    // MARK: - Auth

    private func submit() async {
        isLoading = true
        errorMessage = nil
        notice = nil
        credentialsError = false
        defer { isLoading = false }

        do {
            let token: TokenResponse
            switch mode {
            case .login:
                token = try await APIClient.shared.login(email: email, password: password)
            case .signup:
                // Device locale, not hardcoded: Cliente.idioma is captured
                // once here and inherited by onboarding and the generator.
                let idioma = Locale.current.language.languageCode?.identifier == "es" ? "es" : "en"
                token = try await APIClient.shared.signup(
                    SignupRequest(email: email, password: password, nombre: nombre, idioma: idioma)
                )
            }
            session.store(token: token.accessToken, onboardingComplete: token.onboardingComplete)
        } catch {
            if mode == .login, Self.isCredentialsMismatch(error) {
                credentialsError = true
                errorMessage = "That email or password doesn't match. Try again."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func isCredentialsMismatch(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .notAuthenticated:
            return true
        case .server(let status, _):
            return status == 400 || status == 401 || status == 403 || status == 422
        default:
            return false
        }
    }
}

/// `lucaku.` with the dot in the accent colour (the only decorative use of it).
private struct Wordmark: View {
    var body: some View {
        (Text("lucaku").foregroundStyle(LucakuColor.textPrimary)
         + Text(".").foregroundStyle(LucakuColor.accent))
            .font(.system(size: 28, weight: .heavy))
            .tracking(-0.5)
    }
}

#Preview {
    LoginView()
        .environmentObject(SessionStore())
}
