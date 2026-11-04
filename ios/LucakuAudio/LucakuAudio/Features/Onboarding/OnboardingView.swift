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
///   - 2.12 runs the confirm step. Its task lives on the whole step and a
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
                VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
                    ForEach(flow.messages) { message in
                        MessageRow(message: message)
                    }
                    if flow.isTyping {
                        TypingRow()
                    }
                    promptView
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(LucakuMotion.house) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private var promptView: some View {
        switch flow.prompt {
        case .none:
            EmptyView()
        case .consent:
            ChoiceButtons {
                PrimaryButton(title: "I understand") { Task { await flow.acceptConsent() } }
            }
        case .start:
            StartChoices(flow: flow)
        case .understood:
            UnderstoodCard(flow: flow)
        case .suggestions:
            SuggestionsCard(flow: flow)
        case .categories:
            CategoriesCard(flow: flow)
        case .specifics(let interestId):
            SpecificsCard(flow: flow, interestId: interestId)
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
        case .notifications:
            ChoiceButtons {
                PrimaryButton(title: "Enable notifications") { Task { await flow.notifications(enabled: true) } }
                SecondaryButton(title: "Not now") { Task { await flow.notifications(enabled: false) } }
            }
        case .finish:
            ChoiceButtons {
                PrimaryButton(title: "Take me to Home") { Task { await flow.finishNow() } }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            if speech.isListening {
                ListeningStrip(transcript: speech.transcript)
            }
            HStack(spacing: LucakuSpacing.sp2) {
                HStack(spacing: LucakuSpacing.sp2) {
                    TextField("Message Lucaku", text: $input, axis: .vertical)
                        .font(LucakuTypography.body)
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1...3)
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    micButton
                }
                .padding(.leading, LucakuSpacing.sp4)
                .padding(.trailing, 6)
                .frame(minHeight: 46)
                .background(Capsule().fill(LucakuColor.surface))
                .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))

                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(LucakuColor.bg)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(LucakuColor.textPrimary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Text("Type or say 'I'm done' anytime")
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp2)
        .background(LucakuColor.bg)
        .animation(LucakuMotion.house, value: input.isEmpty)
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
                    flow.dismissSpeaking(speech)
                    speech.transcript = ""
                    do {
                        try await speech.startListening(languageCode: flow.vm.speechLanguage)
                    } catch {
                        listenError = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(speech.isListening ? LucakuColor.bg : LucakuColor.icon)
                .frame(width: 36, height: 36)
                .background(Circle().fill(speech.isListening ? LucakuColor.textPrimary : LucakuColor.iconTile))
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
        case consent
        case start
        case understood
        case suggestions
        case categories
        case specifics(String)
        case time
        case length
        case style
        case voice
        case summary
        case starting
        case notifications
        case finish
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
    @Published private(set) var suggestionChoices: [String] = []
    @Published private(set) var categoryQueue: [String] = []
    @Published private(set) var addedInCurrentCategory = 0
    @Published private(set) var editingAllTopics = false
    @Published var selectedVoice: Voice = .valentina

    private var started = false
    private var confirmedTopicIDs: Set<String> = []
    private var returnToSummary = false
    private var suggestionOffset = 0
    private var addedThisRound: [String] = []
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

    /// 0 topics, 1 delivery, 2 style and voice, 3 review.
    var progressIndex: Int {
        switch prompt {
        case .none, .consent, .start, .understood, .suggestions, .categories, .specifics: return 0
        case .time, .length: return 1
        case .style, .voice: return 2
        case .summary, .starting, .notifications, .finish: return 3
        }
    }

    var topicsToConfirm: [AddedTopic] {
        editingAllTopics ? vm.addedTopics : vm.addedTopics.filter { !confirmedTopicIDs.contains($0.id) }
    }

    func label(forInterest id: String) -> String {
        vm.interestOptions.first(where: { $0.id == id })?.label ?? id
    }

    var deliveryText: String {
        "Every day at \(Self.timeFormatter.string(from: vm.deliveryTime))"
    }

    var lengthText: String {
        vm.maxLengthMinutes.map { "Up to \($0) min" } ?? "As long as it needs"
    }

    var styleText: String { "\(vm.narrationStyle.displayName) style · \(selectedVoice.name)" }

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
        return ["i'm done", "im done", "i am done", "done", "that's all", "thats all", "that's it", "all done"].contains(t)
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

    func dismissSpeaking(_ speech: SpeechService) { speech.stopSpeaking() }

    // MARK: Start / resume

    func begin() async {
        guard !started, let token = tokenProvider() else { return }
        started = true
        await vm.load(token: token)
        guard vm.loadState == .loaded else { started = false; return }

        switch vm.step {
        case .consent:
            await greet()
            await say("One quick thing: what you ask me to follow is personal data under Colombian law (Ley 1581 de 2012). I only use it to build your episodes, and never sell or share it.")
            prompt = .consent
        case .interests, .requests:
            await greet()
            await askTopics()
        case .delivery:
            await say("Welcome back. When do you want it ready each day?")
            prompt = .time
        case .sound:
            await say("Welcome back. How should it sound?")
            prompt = .style
        case .confirm:
            prompt = .starting
        case .notifications:
            await askNotifications()
        case .tour, .done:
            prompt = .finish
        }
    }

    private func greet() async {
        let first = vm.nombre.split(separator: " ").first.map(String.init) ?? ""
        let hello = first.isEmpty ? "Hi!" : "Hi \(first)!"
        await say("\(hello) I'm Lucaku. Let's set up your daily news together. It takes about a minute.")
    }

    private func askTopics() async {
        await say("What do you want me to follow? Say it or type it, like “Arsenal, Formula 1 and AI startups”. Or tap Guide me and I'll help you pick.")
        prompt = .start
    }

    func acceptConsent() async {
        guard prompt == .consent, let token = tokenProvider() else { return }
        prompt = .none
        userSays("I understand")
        await vm.acceptConsent(token: token)
        if await flushError() { prompt = .consent; return }
        await askTopics()
    }

    // MARK: Free text from the input bar

    func submit(_ text: String) async {
        guard prompt != .none, !isTyping else { return }

        if Self.isDonePhrase(text) {
            switch prompt {
            case .start, .understood, .suggestions, .specifics:
                await done(userText: text)
            default:
                await hint(text, "Use the options below to continue.")
            }
            return
        }

        switch prompt {
        case .start, .understood, .suggestions, .specifics:
            await addTopics(from: text)
        case .time:
            await timeTyped(text)
        case .length:
            await lengthTyped(text)
        default:
            await hint(text, "Use the options below to continue.")
        }
    }

    private func hint(_ text: String, _ reply: String) async {
        let saved = prompt
        prompt = .none
        userSays(text)
        await say(reply, delay: 0.4)
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
        var specificInterest: String?
        if case .specifics(let id) = prompt { specificInterest = id }
        let saved = prompt
        prompt = .none
        userSays(text)

        let parts = splitTopics(text)
        let generic = parts.filter { Self.genericTopics.contains($0.lowercased()) }
        let specific = parts.filter { !Self.genericTopics.contains($0.lowercased()) }

        if let first = generic.first {
            await say("\(first.capitalized) is a big area. Which part of it? A team, a league, a person or a question, like “How is Arsenal doing?”")
            if specific.isEmpty { prompt = saved; return }
        }

        let category = specificInterest.map { label(forInterest: $0) }
        var added: [String] = []
        for topic in specific {
            if await vm.addRequest(text: request(forTopic: topic), label: topic, category: category, token: token) {
                added.append(topic)
            } else if await flushError() {
                break
            }
        }

        if added.isEmpty {
            prompt = saved == .understood && topicsToConfirm.isEmpty ? .start : saved
            return
        }
        if specificInterest != nil {
            addedInCurrentCategory += added.count
            await say("Added \(joined(added)). Tap another one, type your own, or go to the next.")
            prompt = saved
            return
        }
        await say("Here's what I understood. Tap ✕ to remove anything that's wrong.")
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
        prompt = .none
        confirmedTopicIDs.formUnion(vm.addedTopics.map(\.id))
        editingAllTopics = false
        userSays(wasEditing ? "Done" : "Yes, that's right")
        if returnToSummary {
            await showSummary()
            return
        }
        await say("Great. I'll follow those every day.")
        suggestionOffset = 0
        addedThisRound = []
        refreshSuggestions()
        await say("You might also like these. Add some, ask for more, or tap I'm done.")
        prompt = .suggestions
    }

    private static let defaultSuggestions = [
        "World Cup", "Champions League", "AI startups", "Amazon stock",
        "Formula 1", "Bitcoin", "Interest rates", "Climate change",
    ]

    private func refreshSuggestions() {
        var pool: [String] = []
        for topic in vm.addedTopics {
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
        for i in 0..<3 {
            let item = unique[(suggestionOffset + i) % unique.count]
            if !picked.contains(item) { picked.append(item) }
        }
        suggestionChoices = picked
    }

    func addSuggestion(_ label: String) async {
        guard prompt == .suggestions, let token = tokenProvider() else { return }
        prompt = .none
        userSays(label)
        if await vm.addRequest(text: request(forTopic: label), label: label, token: token) {
            addedThisRound.append(label)
            confirmedTopicIDs.formUnion(vm.addedTopics.map(\.id))
            refreshSuggestions()
            await say("Added \(joined(addedThisRound)). Here are a few more, or tap I'm done.")
        } else {
            await flushError()
        }
        prompt = .suggestions
    }

    func moreIdeas() async {
        guard prompt == .suggestions else { return }
        prompt = .none
        userSays("More ideas")
        suggestionOffset += 3
        refreshSuggestions()
        await say("Here are a few more, or tap I'm done.")
        prompt = .suggestions
    }

    func done(userText: String = "I'm done") async {
        guard let token = tokenProvider() else { return }
        let saved = prompt
        prompt = .none
        userSays(userText)
        if vm.activeRequestCount < 1 {
            await say("I need at least one topic to build your first episode. What do you want me to follow?")
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
            if await flushError() { prompt = saved; return }
        }
        await say("Great. When do you want it ready each day?")
        prompt = .time
    }

    // MARK: Guide me (2.6-2.8)

    func guideMe() async {
        guard prompt == .start else { return }
        prompt = .none
        userSays("Guide me")
        await say("Pick as many categories as you like. I'll ask about each one.")
        prompt = .categories
    }

    func toggleCategory(_ id: String) { vm.toggleInterest(id) }

    func confirmCategories() async {
        guard prompt == .categories, let token = tokenProvider() else { return }
        let chosen = vm.interestOptions.filter { vm.selectedInterests.contains($0.id) }
        guard !chosen.isEmpty else { return }
        prompt = .none
        userSays(chosen.map(\.label).joined(separator: ", "))
        if vm.step == .interests {
            await vm.continueFromInterests(token: token)
            if await flushError() { prompt = .categories; return }
        }
        categoryQueue = chosen.map(\.id)
        await nextCategory()
    }

    private func nextCategory() async {
        guard let token = tokenProvider() else { return }
        addedInCurrentCategory = 0
        guard !categoryQueue.isEmpty else {
            await done(userText: "That's everything")
            return
        }
        let id = categoryQueue.removeFirst()
        let name = label(forInterest: id)
        await vm.loadSuggestions(interest: id, token: token)
        await say("For \(name), tap what you want, or type your own, like a team, a person or a question.")
        prompt = .specifics(id)
    }

    func pickSpecific(_ suggestion: String, interestId: String) async {
        guard let token = tokenProvider() else { return }
        let name = label(forInterest: interestId)
        prompt = .none
        userSays(suggestion)
        if await vm.addRequest(text: suggestion, label: suggestion, category: name, token: token) {
            addedInCurrentCategory += 1
            await say("Added. Tap another, type your own, or go to the next one.", delay: 0.4)
        } else {
            await flushError()
        }
        prompt = .specifics(interestId)
    }

    func nextOrSkip(interestId: String) async {
        guard let token = tokenProvider() else { return }
        let name = label(forInterest: interestId)
        prompt = .none
        if addedInCurrentCategory == 0 {
            userSays("Skip")
            if await vm.addRequest(text: "Top \(name) stories", label: "Top \(name) stories", category: name, token: token) {
                await say("Okay, I'll cover the top \(name) stories.", delay: 0.5)
            } else {
                await flushError()
            }
        } else {
            userSays("Next category")
        }
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
            await say("I didn't catch that time. Try something like “6:45 am”.", delay: 0.4)
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
        await say("Got it. How long should it run, at most?")
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
            await say("Pick one below, or type a number of minutes.", delay: 0.4)
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
        await say("How should it sound? Pick a style.")
        prompt = .style
    }

    func chooseStyle(_ style: NarrationStyle) async {
        guard prompt == .style else { return }
        prompt = .none
        userSays(style.displayName)
        vm.narrationStyle = style
        await say("And who should read it to you?")
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
        await say("Here's your Lucaku. Ready when you are.")
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

    /// Saves delivery + sound, confirms, and moves on to notifications. Safe
    /// to call again after a failure: each stage only runs if the backend step
    /// hasn't moved past it.
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
        if await flushError() { return }

        switch vm.step {
        case .notifications:
            prompt = .none
            if let message = vm.confirmationMessage { await say(message) }
            await askNotifications()
        case .tour, .done:
            prompt = .finish
        default:
            break
        }
    }

    private func askNotifications() async {
        await say("Want a nudge when your episode is ready? One notification a day.")
        prompt = .notifications
    }

    func notifications(enabled: Bool) async {
        guard prompt == .notifications, let token = tokenProvider() else { return }
        prompt = .none
        userSays(enabled ? "Enable notifications" : "Not now")
        await vm.setNotifications(enabled: enabled, token: token)
        if await flushError() { prompt = .notifications; return }
        await finishNow()
    }

    func finishNow() async {
        guard let token = tokenProvider() else { return }
        prompt = .none
        await vm.finish(token: token)
        if await flushError() { prompt = .finish }
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

enum OnboardingCategories {
    private static let keywords: [(category: String, words: [String])] = [
        ("Sports", ["arsenal", "football", "soccer", "world cup", "champions", "nba", "tennis", "formula", "f1",
                    "millonarios", "nfl", "olympics", "premier", "messi", "djokovic", "golf", "cycling", "league"]),
        ("Technology & AI", ["ai", "openai", "apple", "google", "startups", "startup", "tech", "cybersecurity",
                             "nvidia", "software", "chips"]),
        ("Personal finance", ["savings", "mortgage", "budget", "pension", "taxes", "tax", "retirement"]),
        ("Economy & business", ["stock", "stocks", "amazon", "bitcoin", "crypto", "interest", "oil", "markets",
                                "market", "inflation", "economy", "business", "dollar", "tesla"]),
        ("Politics & government", ["election", "elections", "president", "congress", "senate", "politics", "government"]),
        ("Climate & environment", ["climate", "weather", "emissions", "environment"]),
        ("Health & wellness", ["health", "vaccine", "vaccines", "medicine", "wellness", "cancer"]),
        ("Science & space", ["nasa", "space", "science", "physics"]),
        ("Culture & entertainment", ["movie", "movies", "film", "music", "oscars", "netflix", "celebrity", "culture"]),
        ("Lifestyle & travel", ["travel", "food", "recipes", "fashion", "lifestyle"]),
        ("Colombia & your city", ["colombia", "bogota", "bogotá", "medellin", "medellín", "cali"]),
        ("World", ["war", "ukraine", "gaza", "europe", "china", "world"]),
    ]

    static func guess(for text: String) -> String {
        let lower = text.lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        for entry in keywords {
            for word in entry.words {
                if word.contains(" ") ? lower.contains(word) : words.contains(word) { return entry.category }
            }
        }
        return "Your topics"
    }

    static func suggestions(for category: String) -> [String] {
        switch category {
        case "Sports": return ["World Cup", "Champions League", "Formula 1", "NBA", "Tennis"]
        case "Technology & AI": return ["AI startups", "OpenAI", "Cybersecurity", "Apple"]
        case "Economy & business": return ["Amazon stock", "Interest rates", "Bitcoin", "Oil prices"]
        case "Personal finance": return ["Savings rates", "Mortgage rates", "Inflation"]
        case "Politics & government": return ["US elections", "European Union", "Colombia Congress"]
        case "Climate & environment": return ["Climate change", "Renewable energy", "Extreme weather"]
        case "Health & wellness": return ["Sleep science", "Nutrition", "Mental health"]
        case "Science & space": return ["NASA missions", "Space exploration", "Physics"]
        case "Culture & entertainment": return ["Oscars", "Netflix", "Music releases"]
        case "Lifestyle & travel": return ["Travel deals", "Food trends"]
        case "Colombia & your city": return ["Bogotá news", "Colombian economy"]
        case "World": return ["Ukraine", "Middle East", "China"]
        default: return []
        }
    }

    static func symbol(for label: String) -> String {
        let l = label.lowercased()
        if l.contains("sport") || l.contains("deporte") { return "sportscourt" }
        if l.contains("tech") || l.contains("ai") || l.contains("tecnolog") { return "cpu" }
        if l.contains("personal") { return "banknote" }
        if l.contains("econom") || l.contains("business") || l.contains("negocio") { return "chart.line.uptrend.xyaxis" }
        if l.contains("polit") { return "building.columns" }
        if l.contains("climate") || l.contains("clima") { return "leaf" }
        if l.contains("health") || l.contains("salud") { return "heart" }
        if l.contains("science") || l.contains("ciencia") { return "atom" }
        if l.contains("culture") || l.contains("cultura") || l.contains("entertain") { return "music.note" }
        if l.contains("life") || l.contains("travel") || l.contains("viaje") { return "airplane" }
        if l.contains("colombia") || l.contains("city") || l.contains("ciudad") { return "mappin.and.ellipse" }
        if l.contains("world") || l.contains("mundo") { return "globe" }
        return "newspaper"
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
    var size: CGFloat = 28

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

    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            HStack(spacing: LucakuSpacing.sp3) {
                Avatar(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lucaku")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                    Text(status)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? LucakuColor.textPrimary : LucakuColor.borderSoft)
                        .frame(height: 3)
                }
            }
            .animation(LucakuMotion.house, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of 4")
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp3)
        .background(LucakuColor.bg)
    }
}

private struct MessageRow: View {
    let message: OnboardingChatFlow.Message

    var body: some View {
        switch message.role {
        case .lucaku:
            HStack(alignment: .bottom, spacing: LucakuSpacing.sp2) {
                Avatar()
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LucakuColor.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                    )
                Spacer(minLength: 36)
            }
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LucakuColor.textPrimary)
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
        VStack(alignment: .leading, spacing: 2) {
            if transcript.isEmpty {
                Text("Listening…").foregroundStyle(LucakuColor.textPrimary)
            } else {
                spoken
            }
            Text("Listening… tap the mic again to stop")
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
        }
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

private struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LucakuColor.bg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LucakuColor.textPrimary)
                )
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
            .padding(.leading, 36)
    }
}

private struct CardBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous).fill(LucakuColor.surface))
            .overlay(
                RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                    .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
            )
            .padding(.leading, 36)
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
    var symbol: String?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? LucakuColor.bg : LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(isSelected ? LucakuColor.textPrimary : LucakuColor.fill))
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
                        .font(.system(size: 16, weight: .semibold))
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LucakuColor.textTertiary)
            }
            .padding(LucakuSpacing.sp3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.fill))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Prompt cards

/// 2.1: Guide me. Typing or the mic is the main path; this is the alternative.
private struct StartChoices: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        WrapLayout {
            Chip(title: "Guide me", symbol: "sparkles") { Task { await flow.guideMe() } }
        }
        .padding(.leading, 36)
    }
}

/// 2.3: what I understood. Each topic with its category and a remove button.
private struct UnderstoodCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            CardBox {
                Text(flow.editingAllTopics ? "Your topics" : "What I understood")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
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
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .lineLimit(2)
                            Text(topic.category)
                                .font(LucakuTypography.footnote)
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
                }
                Text("Tap ✕ to remove anything that's wrong")
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .lineLimit(1)
            }
            ChoiceButtons {
                PrimaryButton(
                    title: flow.editingAllTopics ? "Done" : "Yes, that's right",
                    isEnabled: !flow.topicsToConfirm.isEmpty || flow.editingAllTopics
                ) { Task { await flow.confirmUnderstood() } }
            }
        }
    }
}

/// 2.4 / 2.5: suggestions, more ideas, I'm done.
private struct SuggestionsCard: View {
    @ObservedObject var flow: OnboardingChatFlow

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            CardBox {
                Text("You might also like")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                WrapLayout {
                    ForEach(flow.suggestionChoices, id: \.self) { item in
                        Chip(title: item, symbol: "plus") { Task { await flow.addSuggestion(item) } }
                    }
                    Chip(title: "More ideas", symbol: "arrow.triangle.2.circlepath") { Task { await flow.moreIdeas() } }
                }
            }
            ChoiceButtons {
                PrimaryButton(title: "I'm done") { Task { await flow.done() } }
            }
        }
    }
}

/// 2.6: the categories as tiles inside the chat.
private struct CategoriesCard: View {
    @ObservedObject var flow: OnboardingChatFlow
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            CardBox {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(flow.vm.interestOptions) { option in
                        tile(option)
                    }
                }
            }
            ChoiceButtons {
                PrimaryButton(
                    title: flow.vm.selectedInterests.isEmpty ? "Pick at least one" : "Continue",
                    isEnabled: !flow.vm.selectedInterests.isEmpty
                ) { Task { await flow.confirmCategories() } }
            }
        }
    }

    private func tile(_ option: InterestOption) -> some View {
        let selected = flow.vm.selectedInterests.contains(option.id)
        return Button {
            flow.toggleCategory(option.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark" : OnboardingCategories.symbol(for: option.label))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? LucakuColor.bg : LucakuColor.icon)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? LucakuColor.textPrimary : LucakuColor.iconTile)
                    )
                Text(option.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? LucakuColor.textPrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 2.7 / 2.8: one category at a time.
private struct SpecificsCard: View {
    @ObservedObject var flow: OnboardingChatFlow
    let interestId: String

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            CardBox {
                Text(flow.label(forInterest: interestId))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                if flow.vm.loadingSuggestionsFor.contains(interestId) {
                    ProgressView().tint(LucakuColor.textSecondary)
                } else if let suggestions = flow.vm.suggestionsByInterest[interestId], !suggestions.isEmpty {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            Task { await flow.pickSpecific(suggestion, interestId: interestId) }
                        } label: {
                            HStack(spacing: LucakuSpacing.sp3) {
                                Text(suggestion)
                                    .font(LucakuTypography.subhead)
                                    .foregroundStyle(LucakuColor.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(LucakuColor.icon)
                            }
                            .padding(LucakuSpacing.sp3)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.fill))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Type what you want to follow in this category.")
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                }
            }
            ChoiceButtons {
                if flow.addedInCurrentCategory > 0 {
                    PrimaryButton(title: "Next category") { Task { await flow.nextOrSkip(interestId: interestId) } }
                } else {
                    SecondaryButton(title: "Skip this one") { Task { await flow.nextOrSkip(interestId: interestId) } }
                }
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
            Text("When do you want it ready each day?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(2)
            WrapLayout {
                ForEach(options, id: \.0) { option in
                    Chip(title: option.0) { Task { await flow.chooseTime(option.0, hour: option.1, minute: option.2) } }
                }
            }
            Text("Or type a time, like “6:45 am”")
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textTertiary)
                .lineLimit(1)
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
            Text("How long should it run, at most?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(2)
            WrapLayout {
                ForEach(options, id: \.0) { option in
                    Chip(title: option.0) { Task { await flow.chooseLength(option.1, label: option.0) } }
                }
            }
            Text("A ceiling, never a target. A quiet day makes a shorter episode.")
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textTertiary)
                .lineLimit(2)
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
        case .casual: return "Conversational, like a friend catching you up"
        }
    }

    private func name(_ style: NarrationStyle) -> String {
        switch style {
        case .news: return "Straight news"
        case .story: return "Story"
        case .casual: return "Conversational"
        }
    }

    var body: some View {
        CardBox {
            Text("Style")
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
            ForEach(NarrationStyle.allCases) { style in
                OptionRow(title: name(style), subtitle: blurb(style)) {
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
            Text("Voice")
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
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

    private var topicsText: String {
        let labels = flow.vm.addedTopics.map(\.label)
        if labels.isEmpty { return "\(flow.vm.activeRequestCount) topics" }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            CardBox {
                Text("Your Lucaku")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                row(symbol: "star", title: "Following", value: topicsText)
                row(symbol: "clock", title: "Delivery", value: flow.deliveryText)
                row(symbol: "timer", title: "Length", value: flow.lengthText)
                row(symbol: "waveform", title: "Sound", value: flow.styleText)
            }
            ChoiceButtons {
                PrimaryButton(title: "Start my Lucaku") { Task { await flow.startLucaku() } }
                SecondaryButton(title: "Change topics") { Task { await flow.changeTopics() } }
                SecondaryButton(title: "Change delivery or style") { Task { await flow.changeDeliveryOrStyle() } }
            }
        }
    }

    private func row(symbol: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            IconTile(symbol: symbol, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 2.12: starting. Runs the save + confirm sequence.
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
                .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                PrimaryButton(title: "Try again") { Task { await attempt() } }
            }
        }
        .padding(.leading, 36)
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
