import Combine
import SwiftUI

/// Onboarding as a chat with Lucaku (screens spec 2.1-2.12).
///
/// There is no welcome screen: after Create account a chat opens. Lucaku's
/// bubbles sit on the left, the customer's on the right, and interactive cards
/// (understood topics, suggestions, category tiles, option rows, a summary)
/// appear inside the conversation. The input bar is always visible, with a mic
/// that dictates on-device (`SpeechService`, SFSpeechRecognizer) and fills the
/// field live.
///
/// The backend state machine is unchanged and still drives resume
/// (`OnboardingViewModel`): consent -> interests -> requests -> delivery ->
/// sound -> confirm -> notifications -> tour. The chat maps onto it:
///   - 2.1 / 2.3-2.8 (topics) write standing requests through `/requests`;
///   - 2.9 / 2.10 only collect values locally; they are saved with the same
///     two profile writes at "Start my Lucaku" (2.11), so "Change delivery or
///     style" can loop back without needing a backwards step transition;
///   - 2.12 runs the confirm step, then completes the notifications step with
///     "off" (the push-permission ask is meant to move to after Home) and the
///     tour step, then goes to Home. Its task lives on the whole step and a
///     "Try again" button follows any failed attempt, so it can never be a
///     dead-end spinner (see `StartingCard`).
struct OnboardingView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var flow: OnboardingChatFlow
    @StateObject private var speech = SpeechService()

    @State private var input = ""
    @State private var listenError: String?
    @FocusState private var inputFocused: Bool

    init(onFinished: @escaping () -> Void) {
        _flow = StateObject(wrappedValue: OnboardingChatFlow(onFinished: onFinished))
    }

    var body: some View {
        ZStack {
            LucakuColor.bg.ignoresSafeArea()

            switch flow.vm.loadState {
            case .idle, .loading:
                ProgressView().tint(LucakuColor.textSecondary)
            case .failed(let message):
                failedView(message)
            case .loaded:
                chat
            }
        }
        .task { await begin() }
        .onDisappear {
            speech.stopSpeaking()
            speech.stopListening()
        }
        .alert("Couldn't listen", isPresented: Binding(
            get: { listenError != nil },
            set: { if !$0 { listenError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(listenError ?? "")
        }
    }

    private func begin() async {
        flow.tokenProvider = { [weak session] in session?.accessToken }
        await flow.begin()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: LucakuSpacing.sp3) {
            Text("Couldn't load onboarding")
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(2)
            Text(message)
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button("Retry") { Task { await begin() } }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .padding(LucakuSpacing.sp6)
    }

    // MARK: - Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                StatusBarFadeAnchor()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(flow.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message, showAvatar: showAvatar(at: index))
                            .padding(.top, topGap(at: index))
                    }
                    if flow.isTyping {
                        TypingRow().padding(.top, 8)
                    }
                    promptView.padding(.top, 8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, LucakuSpacing.sp4)
                .padding(.top, LucakuSpacing.sp3)
                .padding(.bottom, LucakuSpacing.sp4)
            }
            .statusBarFade()
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: flow.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: flow.isTyping) { _, _ in scrollToBottom(proxy) }
            .onChange(of: flow.prompt) { _, _ in scrollToBottom(proxy) }
            .onChange(of: flow.vm.addedTopics.count) { _, _ in scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatHeader(status: flow.statusLine, step: flow.progressIndex)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
    }

    /// The avatar sits only on the last bubble of a Lucaku run.
    private func showAvatar(at index: Int) -> Bool {
        let messages = flow.messages
        guard messages[index].role == .lucaku else { return false }
        if index == messages.count - 1 { return !flow.isTyping }
        return messages[index + 1].role != .lucaku
    }

    private func topGap(at index: Int) -> CGFloat {
        let messages = flow.messages
        guard index > 0 else { return 0 }
        return messages[index - 1].role == messages[index].role ? 0 : 8
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(LucakuMotion.house) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private var promptView: some View {
        switch flow.prompt {
        case .none:
            EmptyView()
        case .start:
            StartChoices(flow: flow)
        case .understood:
            UnderstoodCard(flow: flow)
        case .suggestions:
            SuggestionsCard(flow: flow)
        case .categories:
            CategoriesCard(flow: flow)
        case .detail:
            DetailCard(flow: flow)
        case .time:
            TimeCard(flow: flow)
        case .length:
            LengthCard(flow: flow)
        case .style:
            StyleCard(flow: flow)
        case .voice:
            VoiceCard(flow: flow)
        case .summary:
            SummaryCard(flow: flow)
        case .starting:
            StartingCard(flow: flow)
        }
    }

    // MARK: - Input bar

    private var hint: String? {
        if speech.isListening { return "Listening… tap the mic again to stop" }
        return flow.inputHint
    }

    private var inputIsEmpty: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if speech.isListening, !speech.transcript.isEmpty {
                ListeningStrip(transcript: speech.transcript)
            }
            if let hint {
                Text(hint)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: LucakuSpacing.sp2) {
                HStack(spacing: LucakuSpacing.sp2) {
                    TextField(flow.inputPlaceholder, text: $input, axis: .vertical)
                        .font(LucakuTypography.body)
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1...3)
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    micButton
                }
                .padding(.leading, LucakuSpacing.sp4)
                .padding(.trailing, 4)
                .frame(minHeight: 46)
                .background(Capsule().fill(LucakuColor.surface))
                .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LucakuColor.bg)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(LucakuColor.textPrimary))
                        .opacity(inputIsEmpty ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(inputIsEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp2)
        .background(LucakuColor.bg)
        .onChange(of: speech.transcript) { _, newValue in
            if speech.isListening { input = newValue }
        }
        .onChange(of: speech.isListening) { _, listening in
            // Saying "I'm done" and stopping the mic sends it straight away.
            if !listening, OnboardingChatFlow.isDonePhrase(input) { send() }
        }
    }

    private var micButton: some View {
        Button {
            Task {
                if speech.isListening {
                    speech.stopListening()
                } else {
                    speech.stopSpeaking()
                    speech.transcript = ""
                    do {
                        try await speech.startListening(languageCode: flow.vm.speechLanguage)
                    } catch {
                        listenError = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: speech.isListening ? "stop.fill" : "mic")
                .font(.system(size: speech.isListening ? 13 : 16, weight: .semibold))
                .foregroundStyle(speech.isListening ? Color.white : LucakuColor.icon)
                .frame(width: 36, height: 36)
                .background(Circle().fill(speech.isListening ? LucakuColor.destructive : LucakuColor.iconTile))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isListening ? "Stop listening" : "Answer by speaking")
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if speech.isListening { speech.stopListening() }
        input = ""
        speech.transcript = ""
        Task { await flow.submit(text) }
    }
}

// MARK: - Chat flow

/// The conversation: messages, the one pending interactive card (`prompt`),
/// and the glue between the customer's choices and `OnboardingViewModel`.
@MainActor
final class OnboardingChatFlow: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role { case lucaku, user }
        let id = UUID()
        let role: Role
        let text: String
    }

    enum Prompt: Equatable {
        case none
        case start
        case understood
        case suggestions
        case categories
        case detail
        case time
        case length
        case style
        case voice
        case summary
        case starting
    }

    enum Voice: String, CaseIterable, Identifiable {
        case valentina, andres
        var id: String { rawValue }
        var name: String { self == .valentina ? "Valentina" : "Andrés" }
        var blurb: String { self == .valentina ? "Warm, calm female voice" : "Clear, steady male voice" }
    }

    let vm: OnboardingViewModel
    var tokenProvider: () -> String? = { nil }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var prompt: Prompt = .none
    @Published private(set) var isTyping = false
    @Published private(set) var isRunningStart = false
    @Published private(set) var editingAllTopics = false
    @Published var selectedVoice: Voice = .valentina

    // Suggestions (2.4 / 2.5)
    @Published private(set) var suggestionChoices: [String] = []
    @Published private(set) var selectedSuggestions: Set<String> = []

    // Guide me (2.6-2.8)
    @Published private(set) var selectedCategoryIds: Set<String> = []
    /// "e.g. Millonarios, inflation, F1" — the first example comes from the
    /// listener's own place so the hint is something they could actually ask
    /// for, rather than a Colombian club shown to someone in Madrid.
    static var inputExample: String {
        let place = OnboardingPlace.current
        let local = place.sports.first ?? place.cities.first ?? "your team"
        return "e.g. \(local), inflation, F1"
    }

    @Published private(set) var categoryQueue: [OnboardingCategories.Spec] = []
    @Published private(set) var currentCategory: OnboardingCategories.Spec?
    @Published private(set) var categoryNumber = 0
    @Published private(set) var categoryTotal = 0
    @Published private(set) var detailChoices: [String] = []
    @Published private(set) var selectedDetails: Set<String> = []
    @Published private(set) var addedInCurrentCategory = 0

    private var started = false
    private var confirmedTopicIDs: Set<String> = []
    private var returnToSummary = false
    private var suggestionOffset = 0
    private var detailOffset = 0
    private var addedThisRound: [String] = []
    private var announcedDone = false
    private var bag = Set<AnyCancellable>()

    init(onFinished: @escaping () -> Void) {
        vm = OnboardingViewModel(onFinished: onFinished)
        vm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: Derived

    var statusLine: String {
        if isTyping { return "Typing…" }
        if prompt == .starting || isRunningStart { return "Setting up your first episode…" }
        return "Your news assistant"
    }

    /// 0 Topics, 1 Details, 2 Delivery, 3 Style.
    var progressIndex: Int {
        switch prompt {
        case .none, .start, .understood, .categories: return 0
        case .suggestions, .detail: return 1
        case .time, .length: return 2
        case .style, .voice, .summary, .starting: return 3
        }
    }

    var inputHint: String? {
        switch prompt {
        case .start: return "Type it, or tap the mic and say it"
        case .suggestions, .detail: return "Type or say “I'm done” anytime"
        case .time: return "Or type a time, like 6:45 am"
        default: return nil
        }
    }

    var inputPlaceholder: String {
        switch prompt {
        case .start, .understood, .suggestions, .summary: return Self.inputExample
        case .detail:
            if let example = currentCategory?.example { return "Add your own, like \(example)" }
            return "Message Lucaku"
        default: return "Message Lucaku"
        }
    }

    var topicsToConfirm: [AddedTopic] {
        editingAllTopics ? vm.addedTopics : vm.addedTopics.filter { !confirmedTopicIDs.contains($0.id) }
    }

    var suggestionSubtitle: String {
        let labels = vm.addedTopics.suffix(3).map(\.label)
        return labels.isEmpty ? "Tap to pick." : "Based on \(joined(labels)). Tap to pick."
    }

    var nextCategoryTitle: String {
        if let next = categoryQueue.first { return "Next: \(next.label)" }
        return "I'm done with details"
    }

    var hasTopics: Bool { vm.activeRequestCount > 0 || !vm.addedTopics.isEmpty }

    var summaryTopics: String {
        let labels = vm.addedTopics.map(\.label)
        if labels.isEmpty { return "\(vm.activeRequestCount) topics" }
        let shown = labels.prefix(5).joined(separator: ", ")
        return labels.count > 5 ? "\(shown) +\(labels.count - 5) more" : shown
    }

    var deliveryTimeText: String { Self.timeFormatter.string(from: vm.deliveryTime) }

    var lengthText: String {
        vm.maxLengthMinutes.map { "\($0) min" } ?? "As long as it needs"
    }

    var styleName: String { Self.styleName(vm.narrationStyle) }

    static func styleName(_ style: NarrationStyle) -> String {
        switch style {
        case .news: return "Straight news"
        case .story: return "Story"
        case .casual: return "Conversational"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    static func isDonePhrase(_ raw: String) -> Bool {
        let t = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return ["i'm done", "im done", "i am done", "done", "that's all", "thats all", "that's it", "all done",
                "i'm done with topics", "i'm done adding topics"].contains(t)
    }

    // MARK: Chat primitives

    private func say(_ text: String, delay: Double = 0.7) async {
        isTyping = true
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        isTyping = false
        messages.append(Message(role: .lucaku, text: text))
    }

    private func userSays(_ text: String) {
        messages.append(Message(role: .user, text: text))
    }

    /// Surfaces a pending view-model error as a Lucaku bubble (the backend
    /// often asks for something more specific, which is part of the chat).
    @discardableResult
    private func flushError() async -> Bool {
        guard let message = vm.errorMessage else { return false }
        vm.errorMessage = nil
        await say(message, delay: 0.3)
        return true
    }

    // MARK: Start / resume

    func begin() async {
        guard !started, let token = tokenProvider() else { return }
        started = true
        await vm.load(token: token)
        guard vm.loadState == .loaded else { started = false; return }

        switch vm.step {
        case .consent:
            // No consent message and no "I understand" gate. Consent is
            // obtained at account creation — the sign-up screen states "By
            // creating an account you agree to the Terms and Privacy Policy.
            // Your topics are never sold or shared." Repeating it here as the
            // first thing a new customer reads opened the product with a legal
            // disclaimer instead of a reason to use it.
            //
            // The server-side record is still written (acceptConsent below),
            // because the backend gates the step on it — it just happens
            // without a screen. Nothing about what is stored or disclosed
            // changes; only where the customer is asked.
            await greet()
            await recordConsentSilently()
        case .interests, .requests:
            await greet()
            await askTopics()
        case .delivery:
            await say("Welcome back. When do you want it ready each day?")
            prompt = .time
        case .sound:
            await say("Welcome back. And how should it sound and read?")
            prompt = .style
        case .confirm, .notifications, .tour, .done:
            prompt = .starting
        }
    }

    private func greet() async {
        let first = vm.nombre.split(separator: " ").first.map(String.init) ?? ""
        let hello = first.isEmpty ? "Hi!" : "Hi \(first)!"
        await say("\(hello) I'm Lucaku. Let's set up your daily news together. It takes about a minute.")
    }

    private func askTopics() async {
        await say("What do you want to follow? Type it, or tap the mic and say it. Be as specific as you like: a team, a company, a city or a person.")
        prompt = .start
    }

    /// Record consent without showing anything.
    ///
    /// The backend will not advance past `.consent` until this is posted, so
    /// it still runs — it simply is not a conversation turn any more. If it
    /// fails we continue to the topics question regardless: a customer must
    /// never be stranded on a blank screen over a record-keeping call, and
    /// `vm.load` re-evaluates the step on the next launch anyway.
    private func recordConsentSilently() async {
        if let token = tokenProvider() {
            await vm.acceptConsent(token: token)
            _ = await flushError()
        }
        await askTopics()
    }

    // MARK: Free text from the input bar

    func submit(_ text: String) async {
        guard prompt != .none, !isTyping else { return }

        if Self.isDonePhrase(text) {
            switch prompt {
            case .start, .understood, .suggestions, .detail:
                await done(userText: text)
            default:
                await hint(text)
            }
            return
        }

        switch prompt {
        case .start, .understood, .suggestions, .detail:
            await addTopics(from: text)
        case .time:
            await timeTyped(text)
        case .length:
            await lengthTyped(text)
        default:
            await hint(text)
        }
    }

    private func hint(_ text: String) async {
        let saved = prompt
        prompt = .none
        userSays(text)
        await say("Tap one of the options above to continue.", delay: 0.4)
        prompt = saved
    }

    // MARK: Topics (2.1, 2.3-2.5)

    private static let genericTopics: Set<String> = [
        "sports", "sport", "news", "politics", "world", "economy", "business", "technology", "tech",
        "science", "health", "climate", "culture", "entertainment", "lifestyle", "travel", "finance",
        "music", "football", "soccer", "movies", "money",
    ]

    private func splitTopics(_ text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: ";", with: ",")
        normalized = normalized.replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
        return normalized.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func request(forTopic topic: String) -> String {
        topic.count >= 5 ? topic : "Latest news on \(topic)"
    }

    func addTopics(from text: String) async {
        guard let token = tokenProvider() else { return }
        let inDetail = prompt == .detail
        let saved = prompt
        prompt = .none
        userSays(text)

        let parts = splitTopics(text)
        let generic = parts.filter { Self.genericTopics.contains($0.lowercased()) }
        let specific = parts.filter { !Self.genericTopics.contains($0.lowercased()) }

        if parts.isEmpty {
            await say("I didn't catch a topic there. Try a team, a company, a city or a person.", delay: 0.4)
            prompt = saved
            return
        }
        if let first = generic.first {
            await say("\(first.capitalized) is a big area. Which part of it? A team, a league, a person or a question, like “How is Arsenal doing?”")
            if specific.isEmpty { prompt = saved; return }
        }

        let category = inDetail ? currentCategory?.label : nil
        var added: [String] = []
        var failedWithMessage = false
        for topic in specific {
            if await vm.addRequest(text: request(forTopic: topic), label: topic, category: category, token: token) {
                added.append(topic)
            } else if await flushError() {
                failedWithMessage = true
                break
            }
        }

        if added.isEmpty {
            if !failedWithMessage {
                await say("I didn't catch a topic there. Try a team, a company, a city or a person.", delay: 0.4)
            }
            prompt = saved == .understood && topicsToConfirm.isEmpty ? .start : saved
            return
        }
        if inDetail {
            addedInCurrentCategory += added.count
            await say("Added \(joined(added)) to \(currentCategory?.label ?? "your topics"). Anything else, or tap Next?")
            prompt = .detail
            return
        }
        await say("Here's what I understood. Did I get it right?")
        prompt = .understood
    }

    func removeTopic(_ topic: AddedTopic) async {
        guard let token = tokenProvider() else { return }
        await vm.removeTopic(id: topic.id, token: token)
        await flushError()
    }

    func confirmUnderstood() async {
        guard prompt == .understood else { return }
        let wasEditing = editingAllTopics
        let count = topicsToConfirm.count
        prompt = .none
        confirmedTopicIDs.formUnion(vm.addedTopics.map(\.id))
        editingAllTopics = false
        userSays(wasEditing ? "Done" : "Yes, that's right")
        if returnToSummary {
            await showSummary()
            return
        }
        await say(count == 1 ? "Great. I'll follow it every day." : "Great. I'll follow those every day.")
        suggestionOffset = 0
        addedThisRound = []
        selectedSuggestions = []
        refreshSuggestions()
        await say("Based on that, you might also like these. Pick any, ask for more, or tell me you're done.")
        prompt = .suggestions
    }

    func addOrChange() async {
        guard prompt == .understood else { return }
        prompt = .none
        userSays("I want to add or change something")
        await say("Sure. Tell me what to add or fix, by typing or with the mic.")
        prompt = .start
    }

    private static let defaultSuggestions = [
        "World Cup", "Champions League", "AI startups", "Amazon stock",
        "Formula 1", "Bitcoin", "Interest rates", "Climate change",
    ]

    private func refreshSuggestions() {
        var pool: [String] = []
        // Most recently added topics first, so the last topic's category leads.
        for topic in vm.addedTopics.reversed() {
            pool.append(contentsOf: OnboardingCategories.suggestions(for: topic.category))
        }
        pool.append(contentsOf: Self.defaultSuggestions)
        let have = Set(vm.addedTopics.map { $0.label.lowercased() })
        var seen = Set<String>()
        let unique = pool.filter { item in
            let key = item.lowercased()
            if have.contains(key) || seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        guard !unique.isEmpty else { suggestionChoices = []; return }
        var picked: [String] = []
        for i in 0..<4 {
            let item = unique[(suggestionOffset + i) % unique.count]
            if !picked.contains(item) { picked.append(item) }
        }
        suggestionChoices = picked
        selectedSuggestions = selectedSuggestions.intersection(picked)
    }

    func toggleSuggestion(_ label: String) {
        if selectedSuggestions.contains(label) { selectedSuggestions.remove(label) } else { selectedSuggestions.insert(label) }
    }

    func addSelectedSuggestions() async {
        guard prompt == .suggestions, !selectedSuggestions.isEmpty, let token = tokenProvider() else { return }
        let labels = suggestionChoices.filter { selectedSuggestions.contains($0) }
        prompt = .none
        userSays(joined(labels))
        var added: [String] = []
        for label in labels {
            if await vm.addRequest(text: request(forTopic: label), label: label, token: token) {
                added.append(label)
            } else if await flushError() {
                break
            }
        }
        selectedSuggestions = []
        if !added.isEmpty {
            confirmedTopicIDs.formUnion(vm.addedTopics.map(\.id))
            suggestionOffset += 4
            refreshSuggestions()
            await say("Added \(joined(added)). Here are a few more, or tap I'm done.")
        }
        prompt = .suggestions
    }

    func suggestMore() async {
        guard prompt == .suggestions else { return }
        prompt = .none
        userSays("Suggest more")
        suggestionOffset += 4
        refreshSuggestions()
        await say("Here are a few more, or tap I'm done.")
        prompt = .suggestions
    }

    /// Ends the topic phase. `userText` nil means no user bubble (the guided
    /// path ran out of categories).
    func done(userText: String? = "I'm done") async {
        guard let token = tokenProvider() else { return }
        let saved = prompt
        prompt = .none
        if let userText { userSays(userText) }
        if vm.activeRequestCount < 1 {
            await say("I need at least one topic to build your first episode. What do you want to follow?")
            prompt = .start
            return
        }
        confirmedTopicIDs.formUnion(vm.addedTopics.map(\.id))
        editingAllTopics = false
        if returnToSummary {
            await showSummary()
            return
        }
        if vm.step == .interests || vm.step == .requests {
            await vm.continueFromRequests(token: token)
            if await flushError() { prompt = saved == .none ? .start : saved; return }
        }
        await say("Perfect. Now let's set up your daily episode.")
        await say("When do you want it ready each day?")
        prompt = .time
    }

    // MARK: Guide me (2.6-2.8)

    func guideMe() async {
        guard prompt == .start else { return }
        prompt = .none
        userSays("Guide me")
        await say("No problem. These are the main news categories.")
        await say("Pick the ones you like. Next we'll get more specific.")
        prompt = .categories
    }

    func toggleCategory(_ id: String) {
        if selectedCategoryIds.contains(id) { selectedCategoryIds.remove(id) } else { selectedCategoryIds.insert(id) }
    }

    func confirmCategories() async {
        guard prompt == .categories, let token = tokenProvider() else { return }
        let chosen = OnboardingCategories.all.filter { selectedCategoryIds.contains($0.id) }
        guard !chosen.isEmpty else { return }
        prompt = .none
        userSays(chosen.map(\.label).joined(separator: ", "))

        // Only ids the backend knows are sent (it has no Lifestyle & travel).
        let known = Set(vm.interestOptions.map(\.id))
        let backendIds = Set(chosen.map(\.id)).intersection(known)
        if vm.step == .interests, !backendIds.isEmpty {
            vm.selectedInterests = backendIds
            await vm.continueFromInterests(token: token)
            if await flushError() { prompt = .categories; return }
        }

        categoryQueue = chosen
        categoryTotal = chosen.count
        categoryNumber = 0
        await say("Thanks for adding \(joined(chosen.map(\.label))).")
        await say("Now let's make it as detailed as you want.")
        await nextCategory()
    }

    private func nextCategory() async {
        addedInCurrentCategory = 0
        selectedDetails = []
        detailOffset = 0
        guard !categoryQueue.isEmpty else {
            currentCategory = nil
            await done(userText: nil)
            return
        }
        let category = categoryQueue.removeFirst()
        currentCategory = category
        categoryNumber += 1
        detailChoices = category.page(offset: 0)
        await say("For \(category.label), for example: \(category.example). Tap what you want, or type your own.")
        prompt = .detail
    }

    func toggleDetail(_ label: String) {
        if selectedDetails.contains(label) { selectedDetails.remove(label) } else { selectedDetails.insert(label) }
    }

    func moreDetailIdeas() async {
        guard prompt == .detail, let category = currentCategory else { return }
        prompt = .none
        userSays("More ideas")
        detailOffset += OnboardingCategories.pageSize
        detailChoices = category.page(offset: detailOffset)
        await say("Here are a few more.", delay: 0.4)
        prompt = .detail
    }

    /// Adds the chips currently toggled on in this category. Returns false if
    /// the backend refused one with a message (already shown in the chat).
    private func addSelectedDetails(token: String, category: OnboardingCategories.Spec) async {
        let labels = detailChoices.filter { selectedDetails.contains($0) }
        for label in labels {
            if await vm.addRequest(text: request(forTopic: label), label: label, category: category.label, token: token) {
                addedInCurrentCategory += 1
            } else if await flushError() {
                break
            }
        }
        selectedDetails = []
    }

    func nextCategoryTapped() async {
        guard prompt == .detail, let category = currentCategory, let token = tokenProvider() else { return }
        let chosen = detailChoices.filter { selectedDetails.contains($0) }
        prompt = .none
        if !chosen.isEmpty { userSays(joined(chosen)) }
        await addSelectedDetails(token: token, category: category)
        if addedInCurrentCategory == 0 {
            if await vm.addRequest(text: "Top \(category.label) stories", label: "Top \(category.label) stories", category: category.label, token: token) {
                await say("Okay, I'll cover the top \(category.label) stories.", delay: 0.5)
            } else {
                await flushError()
            }
        }
        await nextCategory()
    }

    func skipRestOfDetails() async {
        guard prompt == .detail, let category = currentCategory, let token = tokenProvider() else { return }
        prompt = .none
        userSays("I'm done, skip the rest")
        await addSelectedDetails(token: token, category: category)
        var covered = [String]()
        if addedInCurrentCategory == 0 { covered.append(category.label) }
        covered.append(contentsOf: categoryQueue.map(\.label))
        for label in covered {
            _ = await vm.addRequest(text: "Top \(label) stories", label: "Top \(label) stories", category: label, token: token)
        }
        await flushError()
        if !covered.isEmpty { await say("Okay, I'll cover the top stories for \(joined(covered)).", delay: 0.5) }
        categoryQueue = []
        await nextCategory()
    }

    // MARK: Delivery (2.9)

    func chooseTime(_ label: String, hour: Int, minute: Int) async {
        guard prompt == .time else { return }
        prompt = .none
        userSays(label)
        setDeliveryTime(hour: hour, minute: minute)
        await askLength()
    }

    private func timeTyped(_ text: String) async {
        prompt = .none
        userSays(text)
        guard let (hour, minute) = Self.parseTime(text) else {
            await say("I didn't catch the time. Try something like 6:45 am, or tap an option.", delay: 0.4)
            prompt = .time
            return
        }
        setDeliveryTime(hour: hour, minute: minute)
        await askLength()
    }

    private func setDeliveryTime(hour: Int, minute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        vm.deliveryTime = Calendar.current.date(from: components) ?? vm.deliveryTime
    }

    private func askLength() async {
        await say("Got it. How long should your episode be?")
        prompt = .length
    }

    func chooseLength(_ minutes: Int?, label: String) async {
        guard prompt == .length else { return }
        prompt = .none
        userSays(label)
        vm.maxLengthMinutes = minutes
        await askStyle()
    }

    private func lengthTyped(_ text: String) async {
        prompt = .none
        userSays(text)
        let digits = text.filter(\.isNumber)
        guard let minutes = Int(digits), (1...60).contains(minutes) else {
            await say("Tap one of the options above to continue.", delay: 0.4)
            prompt = .length
            return
        }
        vm.maxLengthMinutes = minutes
        await askStyle()
    }

    static func parseTime(_ raw: String) -> (Int, Int)? {
        var s = raw.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        var isPM: Bool?
        if s.hasSuffix("am") { isPM = false; s.removeLast(2) } else if s.hasSuffix("pm") { isPM = true; s.removeLast(2) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let hourValue = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0..<60).contains(minute) else { return nil }
        var hour = hourValue
        if let isPM {
            guard (1...12).contains(hourValue) else { return nil }
            hour = hourValue % 12 + (isPM ? 12 : 0)
        }
        guard (0..<24).contains(hour) else { return nil }
        return (hour, minute)
    }

    // MARK: Style and voice (2.10)

    private func askStyle() async {
        await say("And how should it sound and read?")
        prompt = .style
    }

    func chooseStyle(_ style: NarrationStyle) async {
        guard prompt == .style else { return }
        prompt = .none
        userSays(Self.styleName(style))
        vm.narrationStyle = style
        await say("Last one. Which voice do you prefer?")
        prompt = .voice
    }

    func chooseVoice(_ voice: Voice) async {
        guard prompt == .voice else { return }
        prompt = .none
        userSays(voice.name)
        selectedVoice = voice
        returnToSummary = false
        await showSummary()
    }

    // MARK: Summary (2.11) and start (2.12)

    private func showSummary() async {
        await say("Here's your Lucaku. Ready to start, or want to change anything?")
        prompt = .summary
    }

    func changeTopics() async {
        guard prompt == .summary else { return }
        prompt = .none
        returnToSummary = true
        editingAllTopics = true
        userSays("Change topics")
        await say("Sure. Remove anything you don't want, or tell me what to add.")
        prompt = .understood
    }

    func changeDeliveryOrStyle() async {
        guard prompt == .summary else { return }
        prompt = .none
        returnToSummary = true
        userSays("Change delivery or style")
        await say("No problem. When do you want it ready each day?")
        prompt = .time
    }

    func startLucaku() async {
        guard prompt == .summary else { return }
        prompt = .none
        userSays("Start my Lucaku")
        prompt = .starting
    }

    /// Saves delivery + sound, confirms, completes the notifications step
    /// (left off for now: the push-permission ask belongs after Home) and the
    /// tour step, then hands over to Home. Safe to call again after a
    /// failure: each stage only runs if the backend step hasn't moved past it.
    func runStart() async {
        guard !isRunningStart, let token = tokenProvider() else { return }
        isRunningStart = true
        defer { isRunningStart = false }

        if vm.step == .delivery { await vm.continueFromDelivery(token: token) }
        if vm.step == .sound { await vm.continueFromSound(token: token) }
        if vm.step == .confirm {
            if vm.confirmationMessage == nil { await vm.confirm(token: token) }
            if vm.confirmationMessage != nil { await vm.continueFromConfirm(token: token) }
        }
        if vm.step == .notifications { await vm.setNotifications(enabled: false, token: token) }
        if await flushError() { return }

        if vm.step == .tour || vm.step == .done {
            if !announcedDone {
                announcedDone = true
                await say("Done. I'm researching your first episode now, and your news is already waiting on Home.")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await vm.finish(token: token)
            _ = await flushError()
        }
    }

    private func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

// MARK: - Categories and suggestions

/// Where the listener is. Onboarding's category suggestions used to assume
/// Colombia — the "local" category was literally named "Colombia & your city",
/// which is a label nobody outside Colombia can use, and the lists underneath
/// carried Ecopetrol, CDTs, Millonarios and Karol G.
///
/// The fix is not to make everything generic. The backend's own clarity screen
/// *rejects* vague requests ("How did my favourite team do?" comes back asking
/// which team), so a generic onboarding produces requests that fail later.
/// Instead the country became a variable:
///
/// - Category names are place-neutral ("Local news", "World").
/// - Only the four categories that genuinely depend on where you are take
///   their suggestions from this table: local, politics, markets and sports.
///   Technology, science, health, climate, culture and lifestyle are the same
///   everywhere and were never the problem.
/// - The place is read from the device region, not asked. Onboarding already
///   has enough steps, the region is right for almost everyone, and Interests
///   can change any of it afterwards in a sentence.
/// - Somewhere with no entry here still works: `generic` templates the same
///   shapes off the country's own name, so the app is not broken in a market
///   we have not thought about yet.
struct OnboardingPlace {
    let regionCode: String
    let country: String
    /// Major cities, most prominent first.
    let cities: [String]
    /// How politics is actually named there.
    let politics: [String]
    /// The instruments and institutions people follow there.
    let markets: [String]
    /// Clubs, leagues and teams with a local following.
    let sports: [String]

    static let colombia = OnboardingPlace(
        regionCode: "CO", country: "Colombia",
        cities: ["Bogotá", "Medellín", "Cali", "Barranquilla", "Cartagena", "Santander"],
        politics: ["Congress", "Elections", "The presidency", "Peace process", "Supreme Court", "Corruption cases"],
        markets: ["The peso and the dollar", "Ecopetrol", "Banco de la República rates", "Coffee prices", "Inflation", "CDTs"],
        sports: ["Millonarios FC", "Atlético Nacional", "The national team", "Copa Libertadores", "Egan Bernal", "World Cup"]
    )

    static let mexico = OnboardingPlace(
        regionCode: "MX", country: "Mexico",
        cities: ["Mexico City", "Guadalajara", "Monterrey", "Puebla", "Tijuana", "Mérida"],
        politics: ["Congress", "Elections", "The presidency", "Supreme Court", "Security policy", "State governors"],
        markets: ["The peso and the dollar", "Banxico rates", "Pemex", "The BMV", "Inflation", "Remittances"],
        sports: ["Club América", "Chivas", "The national team", "Liga MX", "Canelo Álvarez", "World Cup"]
    )

    static let spain = OnboardingPlace(
        regionCode: "ES", country: "Spain",
        cities: ["Madrid", "Barcelona", "Valencia", "Seville", "Bilbao", "Málaga"],
        politics: ["Congreso", "Elections", "The government", "Catalonia", "Regional elections", "The courts"],
        markets: ["The euro", "ECB rates", "The IBEX 35", "Inflation", "Santander", "Housing prices"],
        sports: ["Real Madrid", "FC Barcelona", "LaLiga", "The national team", "Champions League", "Carlos Alcaraz"]
    )

    static let unitedStates = OnboardingPlace(
        regionCode: "US", country: "the United States",
        cities: ["New York", "Los Angeles", "Chicago", "Houston", "Miami", "San Francisco"],
        politics: ["Congress", "Elections", "The White House", "The Supreme Court", "State politics", "Immigration policy"],
        markets: ["The Fed", "The S&P 500", "Inflation", "Interest rates", "Nvidia", "Oil prices"],
        sports: ["NFL", "NBA", "MLB", "College football", "Formula 1", "World Cup"]
    )

    static let argentina = OnboardingPlace(
        regionCode: "AR", country: "Argentina",
        cities: ["Buenos Aires", "Córdoba", "Rosario", "Mendoza", "La Plata", "Mar del Plata"],
        politics: ["Congress", "Elections", "The presidency", "The provinces", "Economic reform", "The courts"],
        markets: ["The peso and the dollar", "Inflation", "BCRA rates", "The Merval", "YPF", "Country risk"],
        sports: ["Boca Juniors", "River Plate", "The national team", "Lionel Messi", "Copa Libertadores", "World Cup"]
    )

    static let known: [OnboardingPlace] = [colombia, mexico, spain, unitedStates, argentina]

    /// Anywhere we have no table for. Templated off the country's own name so
    /// the suggestions are still specific enough for the clarity screen.
    static func generic(country: String) -> OnboardingPlace {
        OnboardingPlace(
            regionCode: "",
            country: country,
            cities: ["\(country) news", "Your city", "Local politics", "Transport", "Public safety", "Housing"],
            politics: ["\(country) elections", "\(country) parliament", "The government", "The courts",
                       "Public spending", "Foreign policy"],
            markets: ["\(country) inflation", "\(country) interest rates", "The stock market",
                      "The currency", "Jobs", "Housing prices"],
            sports: ["\(country) national team", "The national league", "World Cup", "Champions League",
                     "Formula 1", "Olympics"]
        )
    }

    /// The device's region, falling back to Colombia — the first market, and a
    /// better default than a generic table for an app that ships in Spanish.
    static var current: OnboardingPlace {
        guard let code = Locale.current.region?.identifier else { return colombia }
        if let match = known.first(where: { $0.regionCode == code }) { return match }
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        return generic(country: name)
    }
}

enum OnboardingCategories {
    static let pageSize = 6

    struct Spec: Identifiable, Equatable {
        let id: String
        let label: String
        let symbol: String
        let example: String
        let topics: [String]

        /// A page of up to `pageSize` chips, wrapping around the list.
        func page(offset: Int) -> [String] {
            guard !topics.isEmpty else { return [] }
            var result: [String] = []
            for i in 0..<min(pageSize, topics.count) {
                result.append(topics[(offset + i) % topics.count])
            }
            return result
        }
    }

    /// The 12 categories, in spec order. Ids match the backend's interest ids
    /// where one exists (`lifestyle` has none). Four of them take their
    /// suggestions from `OnboardingPlace`; the rest are the same everywhere.
    static var all: [Spec] { specs(for: OnboardingPlace.current) }

    static func specs(for place: OnboardingPlace) -> [Spec] {
        [
            Spec(id: "local", label: "Local news", symbol: "mappin.and.ellipse",
                 example: "\(place.cities.first ?? "your city"), or your region",
                 topics: place.cities),
            Spec(id: "politics", label: "Politics & government", symbol: "building.columns",
                 example: "Congress, or the elections",
                 topics: place.politics),
            Spec(id: "world", label: "World", symbol: "globe",
                 example: "the United States, or Ukraine",
                 // The country you are in is not "world news" to you, so it is
                 // deliberately absent from this list.
                 topics: worldTopics(excluding: place)),
            Spec(id: "markets", label: "Economy & business", symbol: "chart.line.uptrend.xyaxis",
                 example: "inflation, or the stock market",
                 topics: place.markets),
            Spec(id: "personal_finance", label: "Personal finance", symbol: "banknote",
                 example: "savings, or taxes",
                 topics: ["Savings", "Taxes", "Mortgages", "Pensions", "Credit cards", "Investing"]),
            Spec(id: "technology", label: "Technology & AI", symbol: "cpu",
                 example: "AI, or Apple",
                 topics: ["AI", "Apple", "OpenAI", "Cybersecurity", "AI startups", "Nvidia"]),
            Spec(id: "science", label: "Science & space", symbol: "atom",
                 example: "space, or NASA missions",
                 topics: ["Space", "NASA missions", "Physics", "Astronomy", "Robotics", "Biology"]),
            Spec(id: "health", label: "Health & wellness", symbol: "heart",
                 example: "running, or sleep",
                 topics: ["Running", "Sleep", "Nutrition", "Mental health", "Cancer research", "Fitness"]),
            Spec(id: "climate", label: "Climate & environment", symbol: "leaf",
                 example: "renewable energy, or extreme weather",
                 topics: ["Climate change", "Renewable energy", "Extreme weather", "Deforestation", "Oceans", "Recycling"]),
            Spec(id: "sports", label: "Sports", symbol: "sportscourt",
                 example: "your club, or the national team",
                 topics: place.sports),
            Spec(id: "entertainment", label: "Culture & entertainment", symbol: "music.note",
                 example: "series, or music releases",
                 topics: ["Series", "Movies", "Music releases", "Oscars", "Netflix", "Books"]),
            Spec(id: "lifestyle", label: "Lifestyle & travel", symbol: "airplane",
                 example: "travel deals, or cars",
                 topics: ["Travel deals", "Cars", "Food", "Fashion", "Home design", "Cities to visit"]),
        ]
    }

    /// Countries and regions, with the listener's own left out — it belongs in
    /// Local news, not World.
    private static func worldTopics(excluding place: OnboardingPlace) -> [String] {
        let pool = ["The United States", "Europe", "China", "Latin America", "Ukraine",
                    "The Middle East", "Venezuela", "Mexico", "Brazil", "India"]
        return Array(pool.filter { !$0.localizedCaseInsensitiveContains(place.country) }.prefix(6))
    }

    private static let keywords: [(category: String, words: [String])] = [
        ("Sports", ["arsenal", "football", "soccer", "world cup", "champions", "nba", "tennis", "formula", "f1",
                    "millonarios", "nfl", "olympics", "premier", "messi", "djokovic", "golf", "cycling", "league"]),
        ("Technology & AI", ["ai", "openai", "apple", "google", "startups", "startup", "tech", "cybersecurity",
                             "nvidia", "software", "chips"]),
        ("Personal finance", ["savings", "mortgage", "budget", "pension", "taxes", "tax", "retirement"]),
        ("Economy & business", ["stock", "stocks", "amazon", "bitcoin", "crypto", "interest", "oil", "markets",
                                "market", "inflation", "economy", "business", "dollar", "tesla", "peso", "euro"]),
        ("Politics & government", ["election", "elections", "president", "congress", "senate", "politics", "government"]),
        ("Climate & environment", ["climate", "weather", "emissions", "environment"]),
        ("Health & wellness", ["health", "vaccine", "vaccines", "medicine", "wellness", "cancer"]),
        ("Science & space", ["nasa", "space", "science", "physics"]),
        ("Culture & entertainment", ["movie", "movies", "film", "music", "oscars", "netflix", "celebrity", "culture"]),
        ("Lifestyle & travel", ["travel", "food", "recipes", "fashion", "lifestyle"]),
        ("World", ["war", "ukraine", "gaza", "europe", "china", "world"]),
    ]

    /// Local news is matched off the listener's own place rather than a fixed
    /// keyword list, so "Medellín" lands in Local news for a Colombian and
    /// "Guadalajara" does for someone in Mexico.
    static func guess(for text: String) -> String {
        let lower = text.lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let place = OnboardingPlace.current
        for local in [place.country] + place.cities where lower.contains(local.lowercased()) {
            return "Local news"
        }
        for entry in keywords {
            for word in entry.words {
                if word.contains(" ") ? lower.contains(word) : words.contains(word) { return entry.category }
            }
        }
        return "Your topics"
    }

    static func suggestions(for category: String) -> [String] {
        all.first(where: { $0.label == category })?.topics ?? []
    }

    static func symbol(for label: String) -> String {
        all.first(where: { $0.label == label })?.symbol ?? "newspaper"
    }
}

// MARK: - Layout helper

/// Wrapping row layout for chips.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Header, bubbles

private struct Avatar: View {
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            Text("l").foregroundStyle(LucakuColor.bg)
            Text(".").foregroundStyle(LucakuColor.accent)
        }
        .font(.system(size: size * 0.55, weight: .heavy))
        .frame(width: size, height: size)
        .background(Circle().fill(LucakuColor.textPrimary))
        .accessibilityHidden(true)
    }
}

private struct ChatHeader: View {
    let status: String
    let step: Int

    private let labels = ["Topics", "Details", "Delivery", "Style"]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: LucakuSpacing.sp3) {
                Avatar(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lucaku")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                    Text(status)
                        .font(LucakuTypography.caption1)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(index <= step ? LucakuColor.textPrimary : LucakuColor.borderSoft)
                            .frame(height: 3)
                        Text(labels[index])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(index == step ? LucakuColor.textPrimary : LucakuColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(LucakuMotion.house, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of 4, \(labels[step])")
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp2)
        .background(LucakuColor.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5)
        }
    }
}

private struct MessageRow: View {
    let message: OnboardingChatFlow.Message
    let showAvatar: Bool

    var body: some View {
        switch message.role {
        case .lucaku:
            HStack(alignment: .bottom, spacing: LucakuSpacing.sp2) {
                if showAvatar {
                    Avatar()
                } else {
                    Color.clear.frame(width: 26, height: 1)
                }
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 6,
                            bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous
                        ).fill(LucakuColor.surface)
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 6,
                            bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous
                        ).strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                    )
                Spacer(minLength: 40)
            }
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous
                        ).fill(LucakuColor.textPrimary)
                    )
            }
        }
    }
}

private struct TypingRow: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: LucakuSpacing.sp2) {
            Avatar()
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(LucakuColor.textSecondary)
                        .frame(width: 7, height: 7)
                        .opacity(phase == index ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule().fill(LucakuColor.surface))
            .overlay(Capsule().strokeBorder(LucakuColor.borderSoft, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Lucaku is typing")
    }
}

/// Live dictation line (2.2): the word being heard right now is the accent.
private struct ListeningStrip: View {
    let transcript: String

    var body: some View {
        spoken
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var spoken: Text {
        let words = transcript.split(separator: " ").map(String.init)
        guard let last = words.last else { return Text("") }
        let head = words.dropLast().joined(separator: " ")
        let lead = head.isEmpty ? Text("") : Text(head + " ").foregroundColor(LucakuColor.textPrimary)
        return lead + Text(last).foregroundColor(LucakuColor.accent)
    }
}

// MARK: - Buttons and card chrome

private let cardIndent: CGFloat = 34

private struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LucakuColor.bg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LucakuColor.textPrimary)
                )
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Filled-gray secondary action.
private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LucakuColor.fill))
        }
        .buttonStyle(.plain)
    }
}

/// Transparent tertiary action.
private struct TextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.plain)
    }
}

/// Stack for the buttons of a simple prompt, aligned under Lucaku's bubble.
private struct ChoiceButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) { content }
            .padding(.leading, cardIndent)
    }
}

private struct CardBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LucakuColor.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LucakuColor.border, lineWidth: 1)
            )
            .padding(.leading, cardIndent)
    }
}

/// Card title (15/700) with an optional 13pt secondary subtitle.
private struct CardTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(2)
            if let subtitle {
                Text(subtitle)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct IconTile: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(LucakuColor.icon)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LucakuColor.iconTile))
    }
}

private struct Chip: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? LucakuColor.bg : LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(Capsule().fill(isSelected ? LucakuColor.textPrimary : LucakuColor.fill))
        }
        .buttonStyle(.plain)
    }
}

/// Outlined quick reply with an icon.
private struct QuickReply: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .overlay(Capsule().strokeBorder(LucakuColor.textPrimary, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Option row: title (one line), blurb (max two lines), radio mark.
private struct OptionRow: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LucakuSpacing.sp3) {
                if let symbol { IconTile(symbol: symbol) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(LucakuColor.textTertiary)
            }
            .padding(LucakuSpacing.sp3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.fill))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Prompt cards

/// 2.1: Guide me (and "I'm done with topics" once any topic exists).
private struct StartChoices: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        WrapLayout {
            QuickReply(title: "Guide me", symbol: "safari") { Task { await flow.guideMe() } }
            if flow.hasTopics {
                QuickReply(title: "I'm done with topics", symbol: "checkmark") { Task { await flow.done(userText: "I'm done with topics") } }
            }
        }
        .padding(.leading, cardIndent)
    }
}

/// 2.3: what I understood. Each topic with its category and a remove button.
private struct UnderstoodCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            CardBox {
                CardTitle(
                    title: flow.editingAllTopics ? "Your topics" : "Here's what I understood",
                    subtitle: "Tap ✕ to remove anything that's wrong."
                )
                if flow.topicsToConfirm.isEmpty {
                    Text("Nothing here yet. Type or say what to follow.")
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                }
                ForEach(flow.topicsToConfirm) { topic in
                    HStack(spacing: LucakuSpacing.sp3) {
                        IconTile(symbol: OnboardingCategories.symbol(for: topic.category), size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topic.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .lineLimit(2)
                            Text(topic.category)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(LucakuColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task { await flow.removeTopic(topic) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LucakuColor.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(LucakuColor.fill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(topic.label)")
                    }
                    .frame(minHeight: 44)
                }
            }
            ChoiceButtons {
                PrimaryButton(
                    title: flow.editingAllTopics ? "Done" : "Yes, that's right",
                    isEnabled: !flow.topicsToConfirm.isEmpty || flow.editingAllTopics
                ) { Task { await flow.confirmUnderstood() } }
                if !flow.editingAllTopics {
                    SecondaryButton(title: "Add or change something") { Task { await flow.addOrChange() } }
                }
            }
        }
    }
}

/// 2.4 / 2.5: multi-select suggestions.
private struct SuggestionsCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        let count = flow.selectedSuggestions.count
        VStack(spacing: LucakuSpacing.sp2) {
            CardBox {
                CardTitle(title: "You might also like", subtitle: flow.suggestionSubtitle)
                WrapLayout {
                    ForEach(flow.suggestionChoices, id: \.self) { item in
                        Chip(title: item, isSelected: flow.selectedSuggestions.contains(item)) {
                            flow.toggleSuggestion(item)
                        }
                    }
                }
            }
            ChoiceButtons {
                PrimaryButton(title: count > 0 ? "Add \(count) selected" : "Add selected", isEnabled: count > 0) {
                    Task { await flow.addSelectedSuggestions() }
                }
                SecondaryButton(title: "Suggest more") { Task { await flow.suggestMore() } }
                TextButton(title: "I'm done adding topics") { Task { await flow.done(userText: "I'm done adding topics") } }
            }
        }
    }
}

/// 2.6: the 12 categories as tiles inside the chat.
private struct CategoriesCard: View {
    @ObservedObject var flow: OnboardingChatFlow
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let count = flow.selectedCategoryIds.count
        VStack(spacing: LucakuSpacing.sp2) {
            CardBox {
                CardTitle(title: "Main news categories", subtitle: "Pick as many as you like.")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(OnboardingCategories.all) { category in
                        tile(category)
                    }
                }
            }
            ChoiceButtons {
                PrimaryButton(
                    title: count > 0 ? "Continue with \(count)" : "Pick at least one",
                    isEnabled: count > 0
                ) { Task { await flow.confirmCategories() } }
            }
        }
    }

    private func tile(_ category: OnboardingCategories.Spec) -> some View {
        let selected = flow.selectedCategoryIds.contains(category.id)
        return Button {
            flow.toggleCategory(category.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark" : category.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? LucakuColor.bg : LucakuColor.icon)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? LucakuColor.textPrimary : LucakuColor.iconTile)
                    )
                Text(category.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LucakuColor.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? LucakuColor.textPrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 2.7 / 2.8: one category at a time, multi-select chips.
private struct DetailCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            CardBox {
                CardTitle(
                    title: flow.currentCategory?.label ?? "Details",
                    subtitle: "\(flow.categoryNumber) of \(flow.categoryTotal). Tap to add, or type your own below."
                )
                WrapLayout {
                    ForEach(flow.detailChoices, id: \.self) { item in
                        Chip(title: item, isSelected: flow.selectedDetails.contains(item)) {
                            flow.toggleDetail(item)
                        }
                    }
                }
            }
            ChoiceButtons {
                PrimaryButton(title: flow.nextCategoryTitle) { Task { await flow.nextCategoryTapped() } }
                SecondaryButton(title: "More ideas") { Task { await flow.moreDetailIdeas() } }
                TextButton(title: "I'm done, skip the rest") { Task { await flow.skipRestOfDetails() } }
            }
        }
    }
}

/// 2.9: delivery time.
private struct TimeCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    private let options: [(String, Int, Int)] = [
        ("6:00 AM", 6, 0), ("6:30 AM", 6, 30), ("7:00 AM", 7, 0),
        ("8:00 AM", 8, 0), ("12:30 PM", 12, 30), ("6:00 PM", 18, 0),
    ]

    var body: some View {
        CardBox {
            WrapLayout {
                ForEach(options, id: \.0) { option in
                    Chip(title: option.0) { Task { await flow.chooseTime(option.0, hour: option.1, minute: option.2) } }
                }
            }
        }
    }
}

/// 2.9: maximum length.
private struct LengthCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    private let options: [(String, Int?)] = [
        ("5 min", 5), ("10 min", 10), ("15 min", 15), ("As long as it needs", nil),
    ]

    var body: some View {
        CardBox {
            WrapLayout {
                ForEach(options, id: \.0) { option in
                    Chip(title: option.0) { Task { await flow.chooseLength(option.1, label: option.0) } }
                }
            }
        }
    }
}

/// 2.10: style.
private struct StyleCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    private func blurb(_ style: NarrationStyle) -> String {
        switch style {
        case .news: return "Neutral and concise, just the facts"
        case .story: return "Narrative, with context and a bit of an arc"
        case .casual: return "Like a friend catching you up"
        }
    }

    var body: some View {
        CardBox {
            ForEach(NarrationStyle.allCases) { style in
                OptionRow(title: OnboardingChatFlow.styleName(style), subtitle: blurb(style)) {
                    Task { await flow.chooseStyle(style) }
                }
            }
        }
    }
}

/// 2.10: voice.
private struct VoiceCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        CardBox {
            ForEach(OnboardingChatFlow.Voice.allCases) { voice in
                OptionRow(title: voice.name, subtitle: voice.blurb, symbol: "waveform") {
                    Task { await flow.chooseVoice(voice) }
                }
            }
        }
    }
}

/// 2.11: your Lucaku.
private struct SummaryCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            CardBox {
                CardTitle(title: "Your Lucaku")
                row(symbol: "star", title: "You follow", value: flow.summaryTopics, first: true)
                row(symbol: "clock", title: "Ready every day at", value: flow.deliveryTimeText)
                row(symbol: "timer", title: "Length", value: flow.lengthText)
                row(symbol: "text.alignleft", title: "Style", value: flow.styleName)
                row(symbol: "waveform", title: "Voice", value: flow.selectedVoice.name)
            }
            ChoiceButtons {
                PrimaryButton(title: "Start my Lucaku") { Task { await flow.startLucaku() } }
                SecondaryButton(title: "Change topics") { Task { await flow.changeTopics() } }
                SecondaryButton(title: "Change delivery or style") { Task { await flow.changeDeliveryOrStyle() } }
            }
        }
    }

    private func row(symbol: String, title: String, value: String, first: Bool = false) -> some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            IconTile(symbol: symbol, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, first ? 0 : LucakuSpacing.sp1)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5).offset(y: -LucakuSpacing.sp2) }
        }
    }
}

/// 2.12: starting. Runs the save + confirm sequence, then Home.
///
/// The task lives on the whole step, never on one branch of the if/else, and
/// `didAttempt` keeps a failed attempt from leaving a permanent spinner: after
/// a failure the "Try again" button calls `attempt()` directly, because `.task`
/// does not refire just because `isRunningStart` flipped back to false. (The
/// earlier version put the task on a branch that `isConfirming` swapped out,
/// which cancelled the request mid-flight and looped forever.)
private struct StartingCard: View {
    @ObservedObject var flow: OnboardingChatFlow
    @State private var didAttempt = false

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            if flow.isRunningStart || !didAttempt {
                HStack(spacing: LucakuSpacing.sp3) {
                    ProgressView().tint(LucakuColor.textSecondary)
                    Text("Setting up your first episode…")
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            } else {
                PrimaryButton(title: "Try again") { Task { await attempt() } }
            }
        }
        .padding(.leading, cardIndent)
        .task {
            guard !didAttempt, !flow.isRunningStart else { return }
            await attempt()
        }
    }

    private func attempt() async {
        await flow.runStart()
        didAttempt = true
    }
}

#Preview {
    OnboardingView(onFinished: {})
        .environmentObject(SessionStore())
}
