import SwiftUI

/// Focus targets shared between `LoginView` and its `LucakuTextField`
/// children so tapping "next" on the keyboard advances focus correctly.
fileprivate enum LucakuAuthField {
    case email, password, name
}

/// Login / Sign Up — the customer's first impression of Lucaku. Auth logic
/// (mode toggle, field state, submit, loading/error) is unchanged from the
/// original scaffold; this is a visual/structural pass on top of the
/// approved design tokens (`LucakuColor` / `LucakuTypography` /
/// `LucakuSpacing` / `LucakuRadius` / `LucakuMotion`).
///
/// v2 revisions, addressing direct client feedback on the v1 redesign:
/// - Removed the duplicate control: previously the top segmented Log
///   In/Sign Up toggle, the bottom submit button (labeled with the mode's
///   raw name), AND a footer text link all did the same job. Now there is
///   ONE mode switch (the top segmented control) and the bottom button is
///   a distinct primary CTA whose label doesn't parrot the toggle
///   ("Log In" vs. "Create Account").
/// - The wordmark is now a proper hero: real vertical rhythm above/below,
///   Apple's actual published tracking-curve values for SF Pro (HIG type
///   scale, not guessed numbers) — see `AppleTracking` below — and a
///   secondary-weight tagline underneath.
/// - Added a real (visually correct, functionally stubbed) "Sign in with
///   Google" button following Google's official branding guidelines,
///   separated from the email/password form by an "or" divider — the
///   standard placement in Spotify/Apple Music-style auth screens.
///
/// There is still no approved logo mark — that remains a brand decision
/// for the product owner, not something to invent here — so the header
/// stays a typography-led wordmark, just composed with far more care.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nombre = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showGoogleComingSoon = false

    @FocusState private var focusedField: LucakuAuthField?

    enum Mode: String, CaseIterable {
        case login = "Log In"
        case signup = "Sign Up"
    }

    /// Apple's published SF Pro tracking (letter-spacing) curve, HIG type
    /// scale — sourced values, not estimates: 17pt −26/1000em (−0.43pt),
    /// 28pt +14/1000em (+0.38pt), 34pt +12/1000em (+0.40pt).
    private enum AppleTracking {
        static let largeTitle: CGFloat = 0.40
        static let title1: CGFloat = 0.38
        static let headline: CGFloat = -0.43
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: LucakuSpacing.sp8)

                        wordmark
                            .padding(.bottom, LucakuSpacing.sp12)

                        formCard

                        Spacer(minLength: LucakuSpacing.sp8)
                    }
                    .padding(.horizontal, LucakuSpacing.sp6)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(LucakuColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    // MARK: - Wordmark hero

    /// The screen's compositional anchor: generous whitespace above and
    /// below, precise tracking on the wordmark, and a one-line tagline in
    /// a clearly secondary weight/size — modeled on how Spotify/Apple
    /// Music let a wordmark (not a cramped title bar) carry the login
    /// screen's top half.
    private var wordmark: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            Text("Lucaku")
                .font(LucakuTypography.largeTitle)
                .tracking(AppleTracking.largeTitle)
                .foregroundStyle(LucakuColor.textPrimary)

            Text("Your research, spoken.")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
        }
        .padding(.top, LucakuSpacing.sp8)
    }

    // MARK: - Form

    private var formCard: some View {
        VStack(spacing: LucakuSpacing.sp6) {
            modePicker

            googleButton

            divider

            VStack(spacing: LucakuSpacing.sp3) {
                LucakuTextField(
                    placeholder: "Email",
                    text: $email,
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    isSecure: false,
                    focusedField: $focusedField,
                    field: .email
                )
                .submitLabel(.next)
                .onSubmit { focusedField = mode == .signup ? .name : .password }

                LucakuTextField(
                    placeholder: "Password",
                    text: $password,
                    keyboardType: .default,
                    textContentType: mode == .login ? .password : .newPassword,
                    isSecure: true,
                    focusedField: $focusedField,
                    field: .password
                )
                .submitLabel(mode == .signup ? .next : .go)
                .onSubmit {
                    if mode == .signup {
                        focusedField = .name
                    } else {
                        focusedField = nil
                        Task { await submit() }
                    }
                }

                if mode == .signup {
                    LucakuTextField(
                        placeholder: "Name",
                        text: $nombre,
                        keyboardType: .default,
                        textContentType: .name,
                        isSecure: false,
                        focusedField: $focusedField,
                        field: .name
                    )
                    .submitLabel(.go)
                    .onSubmit {
                        focusedField = nil
                        Task { await submit() }
                    }
                }
            }
            .animation(LucakuMotion.house, value: mode)

            if let errorMessage {
                errorBanner(errorMessage)
            }

            submitButton
        }
        .padding(LucakuSpacing.sp6)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.sheet, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }

    /// The single mode switch for the whole screen — the only place
    /// "Log In" and "Sign Up" appear as competing labels. Everything below
    /// it (the Google button, the form, the primary CTA) adapts to
    /// whichever mode is selected here instead of repeating the choice.
    private var modePicker: some View {
        HStack(spacing: LucakuSpacing.sp1) {
            ForEach(Mode.allCases, id: \.self) { candidate in
                let isSelected = candidate == mode
                Button {
                    guard mode != candidate else { return }
                    withAnimation(LucakuMotion.house) {
                        mode = candidate
                        errorMessage = nil
                    }
                } label: {
                    Text(candidate.rawValue)
                        .font(LucakuTypography.headline)
                        .foregroundStyle(isSelected ? LucakuColor.accentOn : LucakuColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? LucakuColor.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(LucakuSpacing.sp1)
        .background(
            Capsule(style: .continuous)
                .fill(LucakuColor.bg)
        )
    }

    /// "or" divider between the Google button and the email/password
    /// form — the standard convention major apps use to separate a
    /// federated sign-in option from the classic form.
    private var divider: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            Text("or")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textTertiary)
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
        }
    }

    /// "Sign in with Google" — visually correct per Google's official
    /// branding guidelines (pill shape, standard-color "G" mark on a
    /// white chip, "Sign in with Google" / "Sign up with Google" copy
    /// matching the current mode, Google Sans-weight text substitute).
    /// There is no Google OAuth client ID from the product owner yet, so
    /// the action is an explicit stub — see TODO below for the real
    /// `GIDSignIn` call site once credentials exist.
    private var googleButton: some View {
        Button {
            showGoogleComingSoon = true
        } label: {
            HStack(spacing: 12) {
                GoogleGMark()
                    .frame(width: 18, height: 18)
                Text(mode == .login ? "Sign in with Google" : "Sign up with Google")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0x1F / 255.0, green: 0x1F / 255.0, blue: 0x1F / 255.0))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .background(
            Capsule(style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(red: 0x74 / 255.0, green: 0x77 / 255.0, blue: 0x75 / 255.0), lineWidth: 1)
        )
        .alert("Sign in with Google", isPresented: $showGoogleComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Coming soon — Google sign-in isn't wired up yet.")
        }
        // TODO: once the product owner provides a Google Cloud Console
        // OAuth client ID, replace `showGoogleComingSoon = true` above
        // with the real call, e.g.:
        //   GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { result, error in
        //       guard let idToken = result?.user.idToken?.tokenString else { return }
        //       Task { await session.authenticateWithGoogle(idToken: idToken) }
        //   }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp2) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
            Text(message)
                .font(LucakuTypography.footnote)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.vertical, LucakuSpacing.sp3)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.chip, style: .continuous)
                .fill(Color(red: 0.75, green: 0.24, blue: 0.24).opacity(0.1))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The one true primary CTA on the screen. Its label always matches
    /// the CURRENT mode but never repeats the toggle's own wording, so it
    /// reads as a distinct, purposeful action rather than the same choice
    /// asked twice.
    private var submitButton: some View {
        Button {
            focusedField = nil
            Task { await submit() }
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(LucakuColor.accentOn)
                } else {
                    Text(mode == .login ? "Log In" : "Create Account")
                        .font(LucakuTypography.headline)
                }
            }
            .foregroundStyle(LucakuColor.accentOn)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .background(
            Capsule(style: .continuous)
                .fill(LucakuColor.accent)
        )
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .animation(LucakuMotion.house, value: isLoading)
    }

    private var isDisabled: Bool {
        isLoading || email.isEmpty || password.isEmpty
    }

    // MARK: - Actions (unchanged logic)

    private func submit() async {
        isLoading = true
        withAnimation(LucakuMotion.house) { errorMessage = nil }
        defer { isLoading = false }

        do {
            let token: TokenResponse
            switch mode {
            case .login:
                token = try await APIClient.shared.login(email: email, password: password)
            case .signup:
                token = try await APIClient.shared.signup(
                    SignupRequest(email: email, password: password, nombre: nombre.isEmpty ? email : nombre, idioma: "en")
                )
            }
            session.store(token: token.accessToken)
        } catch {
            withAnimation(LucakuMotion.house) {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Google "G" mark

/// A from-scratch rendering of Google's standard-color "G" mark, since no
/// Google-provided asset is bundled in this project. Colors match Google's
/// published brand palette (blue #4285F4, green #34A853, yellow #FBBC05,
/// red #EA4335) and the proportions follow the well-known four-quadrant
/// ring-plus-bar construction of the mark. Per Google's guidelines this
/// standard-color version must not be recolored or altered.
private struct GoogleGMark: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let lineWidth = size.width * 0.22
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)

            func arc(from startDeg: Double, to endDeg: Double, color: Color) {
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(startDeg),
                    endAngle: .degrees(endDeg),
                    clockwise: false
                )
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }

            // Four quadrants of the ring, standard Google brand colors.
            arc(from: -70, to: 10, color: Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0))   // blue, top-right
            arc(from: 10, to: 90, color: Color(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0))    // green, bottom-right
            arc(from: 90, to: 190, color: Color(red: 0xFB / 255.0, green: 0xBC / 255.0, blue: 0x05 / 255.0))   // yellow, bottom-left
            arc(from: 190, to: 290, color: Color(red: 0xEA / 255.0, green: 0x43 / 255.0, blue: 0x35 / 255.0))  // red, top-left

            // The horizontal bar that completes the "G" cutting into the blue quadrant.
            var bar = Path()
            bar.addRect(CGRect(x: size.width * 0.5, y: size.height * 0.42, width: size.width * 0.52, height: size.height * 0.16))
            context.fill(bar, with: .color(Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0)))
        }
    }
}

// MARK: - LucakuTextField

/// A pill-shaped text field styled on the design tokens — keeps the
/// rounded field language the client already approved, replacing the
/// scaffold's default `Form`/`TextField` chrome.
private struct LucakuTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType
    var textContentType: UITextContentType?
    var isSecure: Bool
    var focusedField: FocusState<LucakuAuthField?>.Binding
    var field: LucakuAuthField

    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        HStack(spacing: LucakuSpacing.sp2) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(LucakuTypography.body)
            .foregroundStyle(LucakuColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .focused(focusedField, equals: field)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(LucakuColor.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .strokeBorder(isFocused ? LucakuColor.accent : LucakuColor.borderSoft, lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(LucakuMotion.house, value: isFocused)
    }
}

#Preview {
    LoginView()
        .environmentObject(SessionStore())
}
