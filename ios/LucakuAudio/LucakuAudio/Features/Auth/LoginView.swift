import SwiftUI

/// Focus targets shared between `LoginView` and its `LucakuTextField`
/// children so tapping "next" on the keyboard advances focus correctly.
fileprivate enum LucakuAuthField {
    case email, password, name
}

/// Login / Sign Up — the customer's first impression of Lucaku. Auth logic
/// (mode toggle, field state, submit, loading/error) is unchanged from the
/// original scaffold; this is a visual pass only, built on the approved
/// design tokens (`LucakuColor` / `LucakuTypography` / `LucakuSpacing` /
/// `LucakuRadius`) so it matches the rest of the app and follows system
/// light/dark automatically.
///
/// There is no approved logo mark yet — that's a brand decision for the
/// product owner, not something to invent here — so the header is a
/// typography-led wordmark (the product name set in Large Title) with a
/// short line of supporting copy, the way a restrained editorial product
/// presents itself before a full mark exists.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nombre = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: LucakuAuthField?

    enum Mode: String, CaseIterable {
        case login = "Log In"
        case signup = "Sign Up"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: LucakuSpacing.sp8)

                        header
                            .padding(.bottom, LucakuSpacing.sp12)

                        formCard

                        footerHint
                            .padding(.top, LucakuSpacing.sp6)

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

    // MARK: - Header / wordmark

    private var header: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            Text("Lucaku")
                .font(LucakuTypography.largeTitle)
                .tracking(-0.4)
                .foregroundStyle(LucakuColor.textPrimary)

            Text("Your research, spoken.")
                .font(LucakuTypography.subhead)
                .tracking(0.2)
                .foregroundStyle(LucakuColor.textSecondary)
        }
    }

    // MARK: - Form

    private var formCard: some View {
        VStack(spacing: LucakuSpacing.sp6) {
            modePicker

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
                    Text(mode.rawValue)
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

    private var footerHint: some View {
        HStack(spacing: LucakuSpacing.sp1) {
            Text(mode == .login ? "New to Lucaku?" : "Already have an account?")
                .foregroundStyle(LucakuColor.textSecondary)
            Button {
                withAnimation(LucakuMotion.house) {
                    mode = mode == .login ? .signup : .login
                    errorMessage = nil
                }
            } label: {
                Text(mode == .login ? "Sign Up" : "Log In")
                    .foregroundStyle(LucakuColor.accent)
            }
            .buttonStyle(.plain)
        }
        .font(LucakuTypography.subhead)
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
