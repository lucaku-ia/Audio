import SwiftUI

/// Login / sign up. Signing in stores the token and the rest of the app takes
/// over; `ContentView` routes to onboarding or the tab bar from there.
///
/// The layout follows the brand showcase (`design/brand/brand_showcase.html`):
/// wordmark, a promise line, a short preview of what a morning actually sounds
/// like, then the form. Two deliberate choices carried over from that design,
/// both answering earlier founder feedback:
///
/// - **One mode switch, at the bottom.** An earlier version had a segmented
///   control at the top *and* a submit button repeating the same word, which
///   read as two competing controls. There is now a single text link under the
///   actions, and sign up is the same screen with a Name row added.
/// - **The screen shows the product.** The app was described as not feeling
///   "live". The preview card speaks a sample line with the words lighting up
///   as they're read, which is the one thing this product actually does.
///
/// Copy is Spanish: `Cliente.idioma` defaults to `es` and the customer base is
/// Spanish-speaking. The rest of the app is still hardcoded English — that's a
/// known gap, tracked in the README's next-steps as UI localization.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nombre = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var spokenWordCount = 0

    @FocusState private var focusedField: Field?

    private enum Field { case email, password, name }

    enum Mode: String {
        case login = "Entrar"
        case signup = "Crear cuenta"
    }

    /// The sample line in the preview card. Split on spaces so each word can
    /// light up in turn — the same "read along" idea the Player uses for real
    /// transcripts.
    private static let sampleWords = "Buenos días. Lo más importante sobre el café hoy, y por qué te afecta."
        .split(separator: " ").map(String.init)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image("Wordmark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.top, LucakuSpacing.sp12)

                Text("Lo que quieres saber, en punto.")
                    .font(LucakuTypography.title1.weight(.semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LucakuSpacing.sp6)

                Text("Dinos qué te interesa. Cada mañana lo investigamos y te lo leemos, a la hora que elijas.")
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LucakuSpacing.sp3)

                previewCard
                    .padding(.top, LucakuSpacing.sp6)

                fields
                    .padding(.top, LucakuSpacing.sp6)

                if let errorMessage {
                    Text(errorMessage)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, LucakuSpacing.sp3)
                }

                primaryButton
                    .padding(.top, LucakuSpacing.sp4)

                googleButton
                    .padding(.top, LucakuSpacing.sp2)

                switchLink
                    .padding(.top, LucakuSpacing.sp4)
                    .padding(.bottom, LucakuSpacing.sp12)
            }
            .padding(.horizontal, LucakuSpacing.sp6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .task { await animateSampleLine() }
    }

    // MARK: - "Así suena tu mañana"

    /// Answers the "it doesn't feel live" note: rather than describing the
    /// product, the login screen performs a few seconds of it.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LucakuColor.accent)
                    .frame(width: 10, height: 10)
                    .scaleEffect(spokenWordCount > 0 && spokenWordCount < Self.sampleWords.count ? 1.0 : 0.72)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: spokenWordCount)
                Text("Así suena tu mañana · 7:00")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
            }

            Text(spokenAttributedLine)
                .font(LucakuTypography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LucakuSpacing.sp4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }

    /// Words already "read" take primary colour; the rest stay tertiary.
    private var spokenAttributedLine: AttributedString {
        var line = AttributedString()
        for (index, word) in Self.sampleWords.enumerated() {
            var piece = AttributedString(index == 0 ? word : " " + word)
            piece.foregroundColor = index < spokenWordCount ? LucakuColor.textPrimary : LucakuColor.textTertiary
            line.append(piece)
        }
        return line
    }

    private func animateSampleLine() async {
        // Runs once on appear, then holds. Deliberately not a loop: a
        // permanently animating login screen is noise, not life.
        for index in 0...Self.sampleWords.count {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 600 : 130))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { spokenWordCount = index }
        }
    }

    // MARK: - Form

    private var fields: some View {
        VStack(spacing: 0) {
            if mode == .signup {
                fieldRow(label: "Nombre") {
                    TextField("Cómo te llamamos", text: $nombre)
                        .textContentType(.name)
                        .focused($focusedField, equals: .name)
                }
                Divider().overlay(LucakuColor.borderSoft)
            }
            fieldRow(label: "Correo") {
                TextField("tu@correo.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focusedField, equals: .email)
            }
            Divider().overlay(LucakuColor.borderSoft)
            fieldRow(label: "Contraseña") {
                SecureField("Obligatoria", text: $password)
                    .textContentType(mode == .signup ? .newPassword : .password)
                    .focused($focusedField, equals: .password)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }

    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Text(label)
                .font(LucakuTypography.body)
                .foregroundStyle(LucakuColor.textSecondary)
                .frame(width: 96, alignment: .leading)
            content()
                .font(LucakuTypography.body)
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .frame(minHeight: 52)
    }

    private var primaryButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(LucakuColor.accentOn)
                } else {
                    Text(mode.rawValue)
                        .font(LucakuTypography.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(LucakuColor.accentOn)
            .background(Capsule().fill(LucakuColor.accent))
        }
        .buttonStyle(.plain)
        .disabled(isLoading || email.isEmpty || password.isEmpty)
        .opacity(isLoading || email.isEmpty || password.isEmpty ? 0.5 : 1)
    }

    /// Visual only for now — no OAuth client ID exists yet, so this states that
    /// plainly rather than failing silently. See the README's blockers.
    private var googleButton: some View {
        Button {
            errorMessage = "Continuar con Google estará disponible pronto."
        } label: {
            HStack(spacing: 10) {
                Image("GoogleGLogo")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Continuar con Google")
                    .font(LucakuTypography.body.weight(.medium))
                    .foregroundStyle(LucakuColor.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                Capsule()
                    .fill(LucakuColor.surface)
                    .overlay(Capsule().strokeBorder(LucakuColor.borderSoft, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var switchLink: some View {
        HStack(spacing: 4) {
            Text(mode == .login ? "¿Primera vez?" : "¿Ya tienes cuenta?")
                .foregroundStyle(LucakuColor.textSecondary)
            Button(mode == .login ? "Crea tu cuenta" : "Entrar") {
                withAnimation(LucakuMotion.house) {
                    mode = mode == .login ? .signup : .login
                    errorMessage = nil
                }
            }
            .foregroundStyle(LucakuColor.accent)
            .fontWeight(.semibold)
        }
        .font(LucakuTypography.subhead)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    // MARK: - Auth (unchanged)

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
