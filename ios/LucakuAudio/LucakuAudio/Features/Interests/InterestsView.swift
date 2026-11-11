import SwiftUI

/// Interests tab, screens 6.1-6.4: a music-library style screen.
/// Add bar (type or say) -> Your topics (tiles) -> Suggested for you (chips)
/// -> Browse all (category tiles) -> Recently removed -> Your episode
/// (delivery settings). Tapping any tile opens a detail sheet (6.2).
///
/// The overall direction is still under review (spec alternatives A-D), so
/// the pieces live in InterestsComponents.swift and the sheet in
/// InterestSheet.swift.
struct InterestsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = InterestsViewModel()
    @StateObject private var speech = SpeechService()
    @FocusState private var addFocused: Bool
    @State private var sheet: InterestSheetTarget?
    @State private var justFollowed: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Couldn't load Interests", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded:
                content
            }
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .task { await load() }
        .sheet(item: $sheet) { target in
            InterestSheet(target: target, viewModel: viewModel, token: session.accessToken)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .alert("Couldn't update interests", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: speech.transcript) { _, text in
            if speech.isListening { viewModel.freeTextQuery = text }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                StatusBarFadeAnchor()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Interests")
                        .font(.interestsTitle)
                        .tracking(-0.5)
                        .foregroundStyle(LucakuColor.textPrimary)
                        .padding(.horizontal, 2)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                        .accessibilityAddTraits(.isHeader)

                    AddTopicBar(
                        text: $viewModel.freeTextQuery,
                        isListening: speech.isListening,
                        isSubmitting: viewModel.isSubmittingFreeText,
                        focus: $addFocused,
                        onSubmit: { Task { await submitFreeText() } },
                        onMic: { toggleMic() }
                    )
                    .id("addBar")

                    if let confirmation = viewModel.confirmation {
                        InterestsConfirmationLine(text: confirmation)
                    }

                    yourTopics(proxy: proxy)
                    suggestions
                    browseAll
                    recentlyRemoved

                    InterestsSectionHeader(title: "Your episode")
                    YourEpisodeCard(viewModel: viewModel, token: session.accessToken)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .statusBarFade()
            .refreshable { await load() }
        }
        .animation(LucakuMotion.house, value: viewModel.confirmation)
        .overlay(alignment: .bottom) {
            if let item = viewModel.undoItem {
                UndoSnackbar(message: "Stopped following \u{201C}\(item.label)\u{201D}.") {
                    Task { await restore(item) }
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(LucakuMotion.house, value: viewModel.undoItem)
    }

    // MARK: - Your topics

    private func yourTopics(proxy: ScrollViewProxy) -> some View {
        let count = viewModel.standingInterests.count + viewModel.topics.count
        return VStack(alignment: .leading, spacing: 0) {
            InterestsSectionHeader(title: "Your topics", trailing: "\(count) following")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(viewModel.standingInterests) { c in
                    InterestTile(title: c.label, caption: "Everything", categoryId: c.id) {
                        sheet = .category(c.id)
                    }
                }
                ForEach(viewModel.topics) { t in
                    InterestTile(title: t.label, caption: t.categoryId.map { viewModel.label(forCategory: $0) } ?? "Your question",
                                 categoryId: t.categoryId) {
                        sheet = .topic(t.id)
                    }
                }
                AddTopicTile {
                    withAnimation { proxy.scrollTo("addBar", anchor: .center) }
                    addFocused = true
                }
            }
        }
    }

    // MARK: - Suggested for you

    private var suggestionLabels: [String] {
        InterestCatalog.popular
            .filter { !viewModel.followsTopic(label: $0) || justFollowed == $0 }
            .prefix(8).map { $0 }
    }

    @ViewBuilder
    private var suggestions: some View {
        if !suggestionLabels.isEmpty {
            InterestsSectionHeader(title: "Suggested for you")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestionLabels, id: \.self) { label in
                        FollowChip(label: label, isOn: viewModel.followsTopic(label: label)) {
                            Task { await toggleTopic(label) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, -16)
        }
    }

    // MARK: - Browse all

    private var browseAll: some View {
        VStack(alignment: .leading, spacing: 0) {
            InterestsSectionHeader(title: "Browse all")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(viewModel.allCategories) { c in
                    InterestTile(title: c.label, caption: nil, categoryId: c.id, height: 76, titleSize: 15,
                                 checked: viewModel.isCategoryActive(c.id)) {
                        sheet = .category(c.id)
                    }
                }
            }
        }
    }

    // MARK: - Recently removed

    @ViewBuilder
    private var recentlyRemoved: some View {
        if !viewModel.recentlyRemoved.isEmpty {
            InterestsSectionHeader(title: "Recently removed")
            VStack(spacing: 0) {
                ForEach(Array(viewModel.recentlyRemoved.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Text(item.label)
                            .font(.system(size: 16))
                            .foregroundStyle(LucakuColor.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button { Task { await restore(item) } } label: {
                            Text("Restore")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(LucakuColor.fill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Restore \(item.label)")
                    }
                    .frame(minHeight: 50)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }

    private func submitFreeText() async {
        guard let token = session.accessToken else { return }
        if speech.isListening { speech.stopListening() }
        addFocused = false
        await viewModel.submitFreeText(token: token)
    }

    private func toggleTopic(_ label: String) async {
        guard let token = session.accessToken else { return }
        if viewModel.followsTopic(label: label) {
            await viewModel.unfollowTopic(label: label, token: token)
        } else {
            justFollowed = label
            await viewModel.followTopic(label: label, token: token)
        }
    }

    private func restore(_ item: InterestsViewModel.Removed) async {
        guard let token = session.accessToken else { return }
        await viewModel.restore(item, token: token)
    }

    private func toggleMic() {
        if speech.isListening {
            speech.stopListening()
        } else {
            Task {
                do { try await speech.startListening(languageCode: "en-US") }
                catch { viewModel.errorMessage = "Couldn't start listening. Check microphone and speech permissions in Settings." }
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
        )
    }
}

#Preview {
    InterestsView()
        .environmentObject(SessionStore())
}
