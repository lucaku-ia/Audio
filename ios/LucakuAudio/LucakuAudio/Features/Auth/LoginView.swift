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
                    .padding(.top, LucakuSpacing.sp6)

                Text("Your news, told your way.")
                    .font(.system(size: 32, weight: .heavy))
                    .lineSpacing(5)
                    .tracking(-0.6)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)

                Text("A short daily audio episode about only what you follow.")
                    .font(.system(size: 17))
                    .lineSpacing(6)            // 17pt text on a 23pt line
                    .foregroundStyle(LucakuColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                episodeTouch
                    .padding(.top, 20)

                modeControl
                    .padding(.top, LucakuSpacing.sp6)

                fields
                    .padding(.top, 14)

                if let message = errorMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 18))
                        Text(message)
                            .font(.system(size: 14))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(LucakuColor.destructive)
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                } else if let notice {
                    Text(notice)
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .padding(.top, 10)
                }

                if mode == .login {
                    Button("Forgot password?") { forgotPassword() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .trailing)
                        .padding(.top, LucakuSpacing.sp1)
                }

                primaryButton
                    .padding(.top, mode == .login ? 6 : 20)

                orDivider
                    .padding(.vertical, 14)

                VStack(spacing: LucakuSpacing.sp2) {
                    providerButton(title: "Continue with Google", message: "Sign in with Google is coming soon.") {
                        Image("GoogleGLogo").resizable().renderingMode(.original).scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                }

                Text(mode == .signup
                     ? "By creating an account you agree to the Terms and Privacy Policy. Your topics are never sold or shared."
                     : "New here? Switch to Create account above.")
                    .font(.system(size: 12))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, LucakuSpacing.sp4)
                    .padding(.bottom, LucakuSpacing.sp12)
            }
            .padding(.horizontal, LucakuSpacing.sp5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            GeometryReader { geo in
                glow(width: geo.size.width)
            }
            .frame(height: 340)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .statusBarFade()
    }

    /// Elliptical glow centred on the top edge: radii 1.2 x width by 0.9 x 340pt,
    /// fading to clear at 70%. Drawn as a circular gradient, then stretched.
    private func glow(width: CGFloat) -> some View {
        let side: CGFloat = 200
        return Rectangle()
            .fill(RadialGradient(colors: [LucakuColor.glow, .clear],
                                 center: .center, startRadius: 0, endRadius: side / 2 * 0.7))
            .frame(width: side, height: side)
            .scaleEffect(x: width * 1.2 / (side / 2), y: 340 * 0.9 / (side / 2))
            .offset(y: -side / 2)
            .frame(width: width, height: 340, alignment: .top)
            .clipped()
    }

    /// Custom two-tab control (track = fill, selected pill = segSelected).
    private var modeControl: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    guard mode != m else { return }
                    mode = m
                    credentialsError = false
                    errorMessage = nil
                    notice = nil
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 14, weight: mode == m ? .bold : .medium))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if mode == m {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LucakuColor.segSelected)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LucakuColor.fill))
        .animation(.easeOut(duration: 0.15), value: mode)
    }

    // MARK: - Promises card

    // MARK: - Brand touch

    /// One episode, drawn in the accent colour, directly under the promise
    /// line. It replaces the three-row "promises" card: the card restated in
    /// prose what this picture shows at a glance — a short episode, ready at
    /// a time you chose — and pushed the actual sign-in form below the fold.
    ///
    /// Decorative only, so it is hidden from VoiceOver: the same facts are in
    /// the line of copy above it.
    private var episodeTouch: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LucakuColor.accent)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LucakuColor.accentOn)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Your episode")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Spacer(minLength: 8)
                    Text("7:00 AM · 8 min")
                        .font(.system(size: 13))
                        .foregroundStyle(LucakuColor.textSecondary)
                }
                waveform
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LucakuColor.surface)
        )
        .shadow(color: .black.opacity(0.10), radius: 11, x: 0, y: 6)
        .accessibilityHidden(true)
    }

    /// 32 bars at fixed heights. The first 11 are solid and the rest faded —
    /// an episode part-way through, not a live meter, so it does not animate.
    private static let waveHeights: [CGFloat] = [
        5, 9, 14, 8, 17, 12, 20, 10, 6, 15, 19, 11, 7, 13, 18, 9,
        16, 12, 6, 10, 17, 14, 8, 19, 11, 7, 15, 10, 13, 6, 9, 5,
    ]
    private static let wavePlayedCount = 11

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(Self.waveHeights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LucakuColor.accent)
                    .frame(height: height)
                    .opacity(index < Self.wavePlayedCount ? 1 : 0.35)
            }
        }
        .frame(height: 20)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: 10) {
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
                HStack(spacing: 0) {
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
                            .font(.system(size: 22))
                            .foregroundStyle(LucakuColor.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                .font(.system(size: 22))
                .foregroundStyle(LucakuColor.textSecondary)
                .frame(width: 26)
            content()
                .font(.system(size: 17))
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: 54)
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
                    Text(mode.rawValue).font(.system(size: 17, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(LucakuColor.bg)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LucakuColor.textPrimary))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.4)
    }

    private var orDivider: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Rectangle().fill(LucakuColor.border).frame(height: 0.5)
            Text("or").font(.system(size: 13)).foregroundStyle(LucakuColor.textSecondary)
            Rectangle().fill(LucakuColor.border).frame(height: 0.5)
        }
    }

    private func providerButton<Icon: View>(title: String, message: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            // Shown in the red error line, deliberately without field rings.
            credentialsError = false
            notice = nil
            errorMessage = message
        } label: {
            HStack(spacing: 10) {
                icon()
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
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
        errorMessage = nil
        if email.trimmingCharacters(in: .whitespaces).isEmpty {
            notice = "Enter your email first, then tap Forgot password."
            focusedField = .email
        } else {
            notice = "Reset link sent to \(email)"
        }
        if let notice {
            UIAccessibility.post(notification: .announcement, argument: notice)
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
            if Self.isCredentialsMismatch(error) {
                credentialsError = true
                errorMessage = "That email or password doesn't match. Try again."
            } else {
                errorMessage = "Something went wrong. Try again."
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
            .font(.system(size: 22, weight: .heavy))
            .tracking(-0.3)
    }
}

#Preview {
    LoginView()
        .environmentObject(SessionStore())
}
