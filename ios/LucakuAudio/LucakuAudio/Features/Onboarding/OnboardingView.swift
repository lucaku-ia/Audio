import SwiftUI

/// Guided onboarding — interests -> shape into standing requests -> delivery
/// time/length -> voice/style -> confirmation -> notifications -> a short
/// tour, matching the Onboarding PRD's flow (Andrés, Draft v4) and driven by
/// the real, resumable backend state machine in `OnboardingViewModel`.
///
/// Voice, per the founder's own ask ("puedes poner voz... si uno no sabe
/// temas"): every step's main prompt can be read aloud
/// (`SpeakerButton`/`SpeechService.speak`, on-device `AVSpeechSynthesizer`),
/// and the free-text request field can be dictated instead of typed
/// (`MicButton`/`SpeechService.startListening`, on-device
/// `SFSpeechRecognizer`) — this is UI narration, not the customer's daily
/// episode voice (that's ElevenLabs, in the Generator). "If someone doesn't
/// know what to ask" is answered by the Requests step's curated suggestions
/// per interest (`GET /onboarding/suggestions`, already built server-side).
struct OnboardingView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel: OnboardingViewModel
    @StateObject private var speech = SpeechService()

    init(onFinished: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(onFinished: onFinished))
    }

    var body: some View {
        ZStack {
            LucakuColor.bg.ignoresSafeArea()

            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView().tint(LucakuColor.accent)
            case .failed(let message):
                failedView(message)
            case .loaded:
                VStack(spacing: 0) {
                    progressBar
                    ScrollView {
                        stepContent
                            .padding(.horizontal, LucakuSpacing.sp4)
                            .padding(.top, LucakuSpacing.sp5)
                            .padding(.bottom, LucakuSpacing.sp8)
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear {
            speech.stopSpeaking()
            speech.stopListening()
        }
        // Titled "One more thing" rather than "Something went wrong": the most
        // common message here isn't a failure but the backend asking the
        // customer to be more specific (e.g. which team, which league), which
        // is a normal part of shaping a request — see APIError.errorDescription.
        .alert("One more thing", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: LucakuSpacing.sp3) {
            Text("Couldn't load onboarding").font(LucakuTypography.headline).foregroundStyle(LucakuColor.textPrimary)
            Text(message).font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.accent)
        }
        .padding(LucakuSpacing.sp6)
    }

    private func load() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }

    // MARK: - Progress

    private static let orderedSteps: [OnboardingStep] = [
        .consent, .interests, .requests, .delivery, .sound, .confirm, .notifications, .tour,
    ]

    private var progressBar: some View {
        let index = Self.orderedSteps.firstIndex(of: viewModel.step) ?? 0
        let fraction = Double(index + 1) / Double(Self.orderedSteps.count)
        return GeometryReader { proxy in
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 3)
                .overlay(alignment: .leading) {
                    Rectangle().fill(LucakuColor.accent).frame(width: proxy.size.width * fraction, height: 3)
                }
        }
        .frame(height: 3)
        .animation(LucakuMotion.house, value: viewModel.step)
        .padding(.top, LucakuSpacing.sp2)
    }

    // MARK: - Step switch

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .consent:
            ConsentStepView(viewModel: viewModel, speech: speech, onContinue: consentContinue)
        case .interests:
            InterestsStepView(viewModel: viewModel, speech: speech, onContinue: interestsContinue)
        case .requests:
            RequestsStepView(viewModel: viewModel, speech: speech, onContinue: requestsContinue)
        case .delivery:
            DeliveryStepView(viewModel: viewModel, speech: speech, onContinue: deliveryContinue)
        case .sound:
            SoundStepView(viewModel: viewModel, speech: speech, onContinue: soundContinue)
        case .confirm:
            ConfirmStepView(viewModel: viewModel, speech: speech, onContinue: confirmContinue)
        case .notifications:
            NotificationsStepView(viewModel: viewModel, speech: speech, onChoice: notificationsChoice)
        case .tour, .done:
            TourStepView(viewModel: viewModel, speech: speech, onFinish: tourFinish)
        }
    }

    private func consentContinue() { Task { if let t = session.accessToken { await viewModel.acceptConsent(token: t) } } }
    private func interestsContinue() { Task { if let t = session.accessToken { await viewModel.continueFromInterests(token: t) } } }
    private func requestsContinue() { Task { if let t = session.accessToken { await viewModel.continueFromRequests(token: t) } } }
    private func deliveryContinue() { Task { if let t = session.accessToken { await viewModel.continueFromDelivery(token: t) } } }
    private func soundContinue() { Task { if let t = session.accessToken { await viewModel.continueFromSound(token: t) } } }
    private func confirmContinue() { Task { if let t = session.accessToken { await viewModel.continueFromConfirm(token: t) } } }
    private func notificationsChoice(_ enabled: Bool) {
        Task { if let t = session.accessToken { await viewModel.setNotifications(enabled: enabled, token: t) } }
    }
    private func tourFinish() { Task { if let t = session.accessToken { await viewModel.finish(token: t) } } }
}

// MARK: - Shared step chrome

private struct StepHeading: View {
    let title: String
    let subtitle: String
    @ObservedObject var speech: SpeechService
    let language: String

    var body: some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                Text(subtitle)
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LucakuSpacing.sp2)
            SpeakerButton(speech: speech, text: "\(title). \(subtitle)", language: language)
        }
        .padding(.bottom, LucakuSpacing.sp5)
    }
}

private struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading { ProgressView().tint(LucakuColor.accentOn) }
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(LucakuColor.accentOn)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(isEnabled ? LucakuColor.accent : LucakuColor.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LucakuColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Reads `text` aloud on tap (or stops if already speaking) — on-device TTS,
/// see `SpeechService.speak`.
private struct SpeakerButton: View {
    @ObservedObject var speech: SpeechService
    let text: String
    let language: String

    var body: some View {
        Button {
            if speech.isSpeaking {
                speech.stopSpeaking()
            } else {
                speech.speak(text, languageCode: language)
            }
        } label: {
            Image(systemName: speech.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LucakuColor.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LucakuColor.accentTint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isSpeaking ? "Stop reading aloud" : "Read this aloud")
    }
}

/// Dictates into `text` while held active — on-device speech-to-text, see
/// `SpeechService.startListening`. Live-updates `text` as partial results
/// arrive, matching the mic-button idiom of Messages/Search fields.
private struct MicButton: View {
    @ObservedObject var speech: SpeechService
    let language: String
    @Binding var text: String
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task {
                if speech.isListening {
                    speech.stopListening()
                } else {
                    do {
                        try await speech.startListening(languageCode: language)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(speech.isListening ? LucakuColor.accentOn : LucakuColor.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(speech.isListening ? LucakuColor.accent : LucakuColor.accentTint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isListening ? "Stop listening" : "Answer by speaking")
        .onChange(of: speech.transcript) { _, newValue in
            if speech.isListening { text = newValue }
        }
        .alert("Couldn't listen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

// MARK: - Step 0: Consent

private struct ConsentStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void

    private var body_: String {
        "Lucaku researches whatever you tell it to follow, and reads it back to you every day. The topics and questions you enter are personal data under Colombian law (Ley 1581 de 2012) — they're used only to build your episodes, never sold or shared."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Welcome to Lucaku",
                subtitle: "Before we start, a quick word on your data.",
                speech: speech, language: viewModel.speechLanguage
            )
            Text(body_)
                .font(LucakuTypography.body)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp6)
            PrimaryButton(title: "I understand, let's go", action: onContinue)
        }
    }
}

// MARK: - Step 1: Interests

private struct InterestsStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "What do you care about?",
                subtitle: "Pick as many as you like — you'll turn these into real questions next.",
                speech: speech, language: viewModel.speechLanguage
            )
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.interestOptions) { option in
                    InterestChip(
                        label: option.label,
                        isSelected: viewModel.selectedInterests.contains(option.id),
                        onTap: { viewModel.toggleInterest(option.id) }
                    )
                }
            }
            .padding(.bottom, LucakuSpacing.sp6)
            PrimaryButton(
                title: "Continue",
                isEnabled: !viewModel.selectedInterests.isEmpty,
                action: onContinue
            )
        }
    }
}

private struct InterestChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
                Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? LucakuColor.accentOn : LucakuColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: LucakuRadius.chip, style: .continuous)
                    .fill(isSelected ? LucakuColor.accent : LucakuColor.surface2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 2: Requests (the one non-skippable step)

private struct RequestsStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Turn that into questions",
                subtitle: "Approve a suggestion, or say what you want to know in your own words.",
                speech: speech, language: viewModel.speechLanguage
            )

            ForEach(Array(viewModel.selectedInterests).sorted(), id: \.self) { interestId in
                InterestSuggestionsSection(interestId: interestId, viewModel: viewModel, speech: speech)
                    .padding(.bottom, LucakuSpacing.sp5)
            }

            FreeTextRequestField(viewModel: viewModel, speech: speech)
                .padding(.bottom, LucakuSpacing.sp5)

            if !viewModel.addedTopics.isEmpty {
                AddedTopicsList(topics: viewModel.addedTopics)
                    .padding(.bottom, LucakuSpacing.sp6)
            }

            PrimaryButton(
                title: viewModel.activeRequestCount >= 1
                    ? "Continue with \(viewModel.activeRequestCount) topic\(viewModel.activeRequestCount == 1 ? "" : "s")"
                    : "Add at least one topic to continue",
                isEnabled: viewModel.activeRequestCount >= 1,
                action: onContinue
            )
        }
    }
}

private struct InterestSuggestionsSection: View {
    let interestId: String
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    @EnvironmentObject private var session: SessionStore
    @State private var addedSuggestions: Set<String> = []

    private var label: String {
        viewModel.interestOptions.first(where: { $0.id == interestId })?.label ?? interestId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)

            if viewModel.loadingSuggestionsFor.contains(interestId) {
                ProgressView().tint(LucakuColor.accent).padding(.vertical, LucakuSpacing.sp2)
            } else if let suggestions = viewModel.suggestionsByInterest[interestId] {
                VStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        SuggestionRow(
                            text: suggestion,
                            isAdded: addedSuggestions.contains(suggestion),
                            onAdd: { await addSuggestion(suggestion) }
                        )
                    }
                }
            }
        }
        .task {
            guard let token = session.accessToken else { return }
            await viewModel.loadSuggestions(interest: interestId, token: token)
        }
    }

    private func addSuggestion(_ text: String) async {
        guard let token = session.accessToken else { return }
        if await viewModel.addRequest(text: text, token: token) {
            addedSuggestions.insert(text)
        }
    }
}

private struct SuggestionRow: View {
    let text: String
    let isAdded: Bool
    let onAdd: () async -> Void
    @State private var isSubmitting = false

    var body: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Text(text)
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { isSubmitting = true; await onAdd(); isSubmitting = false }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().tint(LucakuColor.accent)
                    } else {
                        Image(systemName: isAdded ? "checkmark" : "plus")
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isAdded ? LucakuColor.accentOn : LucakuColor.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isAdded ? LucakuColor.accent : LucakuColor.accentTint))
            }
            .buttonStyle(.plain)
            .disabled(isAdded || isSubmitting)
        }
        .padding(LucakuSpacing.sp3)
        .background(RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous).fill(LucakuColor.surface2))
    }
}

private struct FreeTextRequestField: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or ask anything else")
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)
            HStack(spacing: 8) {
                TextField("Type or tap the mic to speak…", text: $viewModel.freeText, axis: .vertical)
                    .font(LucakuTypography.body)
                    .padding(.horizontal, LucakuSpacing.sp3)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous).fill(LucakuColor.surface2))
                MicButton(speech: speech, language: viewModel.speechLanguage, text: $viewModel.freeText)
                Button {
                    Task {
                        guard let token = session.accessToken else { return }
                        if await viewModel.addRequest(text: viewModel.freeText, token: token) {
                            viewModel.freeText = ""
                        }
                    }
                } label: {
                    if viewModel.isSubmittingRequest {
                        ProgressView().tint(LucakuColor.accentOn).frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LucakuColor.accentOn)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(LucakuColor.accent))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.freeText.trimmingCharacters(in: .whitespaces).count < 5 || viewModel.isSubmittingRequest)
            }
        }
    }
}

private struct AddedTopicsList: View {
    let topics: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Added").font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
            FlowChips(items: topics)
        }
    }
}

/// Simple wrapping chip row (fixed-height rows via LazyVGrid's adaptive
/// columns) — enough for a short "here's what you added" summary; doesn't
/// need SearchView's true flex-wrap `FlowLayout` for this use.
private struct FlowChips: View {
    let items: [String]
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(LucakuColor.accentTint))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Step 3: Delivery

private struct DeliveryStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void

    private let lengthPresets: [Int?] = [5, 10, 15, nil]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "When should it arrive?",
                subtitle: "Your first episode arrives today if there's still time — every day after that, at this time.",
                speech: speech, language: viewModel.speechLanguage
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Delivery time").font(LucakuTypography.headline).foregroundStyle(LucakuColor.textPrimary)
                DatePicker("", selection: $viewModel.deliveryTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, LucakuSpacing.sp6)

            VStack(alignment: .leading, spacing: 6) {
                Text("Maximum length").font(LucakuTypography.headline).foregroundStyle(LucakuColor.textPrimary)
                Text("A ceiling, never a target — a quiet day makes a shorter episode.")
                    .font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
                HStack(spacing: 8) {
                    ForEach(lengthPresets, id: \.self) { preset in
                        LengthChip(
                            label: preset.map { "\($0)m" } ?? "No limit",
                            isSelected: viewModel.maxLengthMinutes == preset,
                            onTap: { viewModel.maxLengthMinutes = preset }
                        )
                    }
                }
            }
            .padding(.bottom, LucakuSpacing.sp6)

            PrimaryButton(title: "Continue", action: onContinue)
        }
    }
}

private struct LengthChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? LucakuColor.accentOn : LucakuColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(isSelected ? LucakuColor.accent : LucakuColor.surface2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4: Sound

private struct SoundStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "How should it sound?",
                subtitle: "You can change this anytime in Settings.",
                speech: speech, language: viewModel.speechLanguage
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Narration style").font(LucakuTypography.headline).foregroundStyle(LucakuColor.textPrimary)
                ForEach(NarrationStyle.allCases) { style in
                    StyleRow(
                        title: style.displayName,
                        subtitle: styleDescription(style),
                        isSelected: viewModel.narrationStyle == style,
                        onTap: { viewModel.narrationStyle = style }
                    )
                }
            }
            .padding(.bottom, LucakuSpacing.sp8)

            PrimaryButton(title: "Continue", action: onContinue)
        }
    }

    private func styleDescription(_ style: NarrationStyle) -> String {
        switch style {
        case .news: return "Neutral and concise — just the facts"
        case .story: return "Narrative, with context and a bit of an arc"
        case .casual: return "Conversational, like a friend catching you up"
        }
    }
}

private struct StyleRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: LucakuSpacing.sp3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(LucakuTypography.body).foregroundStyle(LucakuColor.textPrimary)
                    Text(subtitle).font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
                }
                Spacer(minLength: LucakuSpacing.sp2)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? LucakuColor.accent : LucakuColor.textTertiary)
            }
            .padding(LucakuSpacing.sp3)
            .background(RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous).fill(LucakuColor.surface2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 5: Confirm

private struct ConfirmStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onContinue: () -> Void
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = viewModel.confirmationMessage {
                StepHeading(title: "You're set", subtitle: message, speech: speech, language: viewModel.speechLanguage)
                    .onAppear { speech.speak(message, languageCode: viewModel.speechLanguage) }
                PrimaryButton(title: "Continue", action: onContinue)
            } else if viewModel.isConfirming {
                ProgressView().tint(LucakuColor.accent).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Color.clear.frame(height: 1)
                    .task {
                        guard let token = session.accessToken else { return }
                        await viewModel.confirm(token: token)
                    }
            }
        }
    }
}

// MARK: - Step 6: Notifications

private struct NotificationsStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onChoice: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Get a nudge when it's ready?",
                subtitle: "One notification a day, right when your episode is ready to play.",
                speech: speech, language: viewModel.speechLanguage
            )
            PrimaryButton(title: "Enable notifications", action: { onChoice(true) })
                .padding(.bottom, LucakuSpacing.sp2)
            SecondaryButton(title: "Not now", action: { onChoice(false) })
        }
    }
}

// MARK: - Step 7: Tour / finish

private struct TourStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var speech: SpeechService
    let onFinish: () -> Void

    private let highlights: [(icon: String, title: String, body: String)] = [
        ("house.fill", "Home", "Today's episode and what's coming next"),
        ("magnifyingglass", "Search", "Find anything from your past episodes, or start tracking something new"),
        ("star.fill", "Interests", "See and manage everything Lucaku researches for you"),
        ("gearshape.fill", "Settings", "Voice, delivery time, and your account"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "One quick look around",
                subtitle: "Here's where everything lives.",
                speech: speech, language: viewModel.speechLanguage
            )
            VStack(spacing: 0) {
                ForEach(Array(highlights.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: LucakuSpacing.sp3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LucakuColor.accent)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(LucakuColor.accentTint))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(LucakuTypography.body).foregroundStyle(LucakuColor.textPrimary)
                            Text(item.body).font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
                        }
                    }
                    .padding(.vertical, LucakuSpacing.sp3)
                    .overlay(alignment: .bottom) {
                        if index < highlights.count - 1 {
                            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.bottom, LucakuSpacing.sp6)
            PrimaryButton(title: "Start listening", action: onFinish)
        }
    }
}

#Preview {
    OnboardingView(onFinished: {})
        .environmentObject(SessionStore())
}
