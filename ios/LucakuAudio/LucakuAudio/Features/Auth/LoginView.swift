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
///
/// v3 revision — composition/hierarchy pass, addressing "still dont like
/// the log in and feel is weird organize... look at best in class."
/// No tokens, colors, the wordmark, or the Google button changed; only
/// how the same pieces are arranged on the screen. Grounded in a real
/// teardown pass (not guessed) of Spotify's, Apple's, Notion's, and
/// Duolingo's auth/sign-in flows, plus write-ups on what makes generated
/// UI read as generic:
/// - v2 wrapped the whole form in a white "surface" card floating with
///   equal margins on a gray page, then vertically centered that card
///   with two equal `Spacer`s so the wordmark+card block sat dead-center
///   with matching empty space above and below. Symmetric centering with
///   nothing else driving the composition is exactly the "AI slop" tell
///   design teardowns call out — "everything centered ... is what you
///   get when nobody made a decision" — and a white rounded rectangle
///   floating on a tinted background reads as a stock "card-in-card"
///   modal rather than a screen someone actually composed (see
///   superdesign.dev/blog/why-ai-design-looks-generic and
///   dev.to/quintetkit/why-ai-generated-screens-look-ai-like-isnt-a-taste-issue).
/// - Real full-screen native auth (Apple's own ID sign-in sheet, Notion
///   and Spotify's mobile login) doesn't nest a second surface inside
///   the page background — the page IS the surface. So v3 drops the
///   floating card and lets the wordmark, mode switch, Google button,
///   and form sit directly on `LucakuColor.bg`, grouped by spacing and
///   the "or" divider instead of a box.
/// - v3 also top-anchors the layout instead of vertically centering it.
///   Login UX guidance (Descope's login-UI writeup; LogRocket's Spotify
///   teardown) and Apple HIG's "avoid making people scroll to see the
///   [sign-in] button" both point the same way: weight content toward
///   the upper-middle so it's already positioned correctly once the
///   keyboard appears, rather than parking it in a spot that only looks
///   right with the keyboard down.
/// - The Google button keeps the exact same height (52pt) as the primary
///   submit button — per Apple HIG's Sign in with Apple guidance, a
///   federated sign-in control should be "no smaller than other sign-in
///   buttons" it sits next to, so it reads as an equally valid path in,
///   not a subordinate option.
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

    /// v3: top-anchored, single-plane composition. No more equal-Spacer
    /// vertical centering and no more nesting the whole form in a second
    /// "surface" card floating on the page background — see the header
    /// note above for why (real full-screen native auth doesn't nest a
    /// card inside the page; the page is the surface). Everything now
    /// sits directly on `LucakuColor.bg`, grouped by spacing and the
    /// existing "or" divider instead of a box.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LucakuSpacing.sp8) {
                    wordmark

                    VStack(spacing: LucakuSpacing.sp6) {
                        modePicker
                        googleButton
                        divider
                        formFields

                        if let errorMessage {
                            errorBanner(errorMessage)
                        }

                        submitButton
                    }
                }
                .padding(.horizontal, LucakuSpacing.sp6)
                .padding(.top, LucakuSpacing.sp8)
                .padding(.bottom, LucakuSpacing.sp12)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LucakuColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    // MARK: - Wordmark hero

    /// The screen's compositional anchor. v2 centered the wordmark+form
    /// block dead in the middle of the screen with equal empty space
    /// above and below; v3 instead weights it toward the upper-middle —
    /// a fixed top inset (not a stretchy `Spacer`) — so the composition
    /// reads as deliberately placed rather than mathematically balanced,
    /// and so it's already sitting where it needs to be once the
    /// keyboard comes up for email/password entry.
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
    }

    // MARK: - Form

    /// The email/password fields, unchanged in behavior from v2 — pulled
    /// into their own subview only so `body` reads as one flat, legible
    /// stack instead of a deeply nested card.
    private var formFields: some View {
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
    }

    /// The single mode switch for the whole screen — the only place
    /// "Log In" and "Sign Up" appear as competing labels. Everything below
    /// it (the Google button, the form, the primary CTA) adapts to
    /// whichever mode is selected here instead of repeating the choice.
    ///
    /// v3: now that this sits directly on `LucakuColor.bg` (no white card
    /// behind it any more), the track uses `LucakuColor.surface` instead
    /// of `.bg` so it still reads as a distinct control rather than
    /// disappearing into the page.
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
                .fill(LucakuColor.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
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
    /// branding guidelines (pill shape, official four-color "G" mark
    /// rendered from a vector asset in `Assets.xcassets/GoogleGLogo`
    /// rather than hand-approximated with shapes, on a white chip,
    /// "Sign in with Google" / "Sign up with Google" copy matching the
    /// current mode, Google Sans-weight text substitute). There is no
    /// Google OAuth client ID from the product owner yet, so the action
    /// is an explicit stub — see TODO below for the real `GIDSignIn`
    /// call site once credentials exist.
    private var googleButton: some View {
        Button {
            showGoogleComingSoon = true
        } label: {
            HStack(spacing: 12) {
                Image("GoogleGLogo")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
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
