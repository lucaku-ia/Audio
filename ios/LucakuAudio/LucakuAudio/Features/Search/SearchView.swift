import SwiftUI

/// Search tab — built against the approved mockup at
/// /tmp/lucaku_design/search_interests_v3.html's "SEARCH VIEW" (the
/// "INTERESTS VIEW" half of that same file is a separate screen, out of
/// scope here). Visual tokens come only from LucakuColor/Typography/
/// Spacing/Radius/Motion (DesignSystem/) and the row/section patterns
/// already established in Features/Home — nothing here invents a color,
/// font size, spacing value, or radius.
///
/// This screen's own view/viewmodel files only — per the task, the
/// concurrent tab-bar restructure (adding a real "Search" tab) wires this
/// into navigation; ContentView.swift / MainTabView are untouched here.
///
/// ── REAL vs. HONESTLY-OMITTED, precisely ──────────────────────────────────
///
/// REAL, backend-backed:
/// • Keyword search — GET /api/search/query (backend/app/api/routes/
///   search.py): PostgreSQL full-text search over Episode.headline,
///   Block.summary and Request.raw_text, scoped to the customer. Powers
///   "From your episodes" (headline + matched-block snippets, real
///   fecha/start_s) and a real "Already tracking this" section for
///   `unmatched_requests` (a standing request whose raw_text matched but
///   which hasn't produced an episode yet — the mockup has no equivalent
///   section, but the field the real API returns here is too informative
///   to silently drop).
/// • "Add as a new interest" — POST /api/requests (kind: standing,
///   created_from: "search"), a real, already-existing enum value and
///   endpoint. See CreateRequestBody's doc comment for why a standing
///   Request *is* the real backend object behind "interest tracking" —
///   there is no separate interests table/endpoint. GET /api/requests?
///   status=active is used to avoid re-offering to add a topic that's
///   already tracked.
/// • "Suggested for you" — GET /api/home's `shared_inventory` (real,
///   interest-tag-derived: a headline + a `reason` sentence like "Because
///   you follow technology"). Tapping a suggestion fills the field with
///   the real headline and searches it, same as the mockup's
///   `data-fill` rows, just sourced from real data instead of fixture copy.
///
/// HONESTLY OMITTED (no real backend support — not faked):
/// • The mockup's curated multi-suggestion "Add as a new interest" rows
///   (e.g. "Federal Reserve policy" / "Fed chair succession watch" as two
///   distinct, differently-worded suggestions derived from one query) needs
///   a topic-extraction/semantic layer that doesn't exist (see search.py's
///   own module docstring: the semantic/AI-answering feature is explicitly
///   P1, not built). What ships instead is one explicit, honest row: add
///   the literal search text itself as a new standing interest.
/// • Natural-language / semantic search ("answer_from_history") — search.py
///   states this needs the AI Platform's shared semantic index, which does
///   not exist yet. Only real keyword search is wired up.
/// • Per-interest cadence ("Every weekday morning", "Weekly") shown on the
///   mockup's Interests screen has no equivalent here since Search doesn't
///   touch that screen, but note for whoever builds Interests next: same
///   gap HomeComponents.swift's InterestsSectionView already documents.
struct SearchView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                LucakuColor.bg.ignoresSafeArea()

                ScrollView {
                    content
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .padding(.top, LucakuSpacing.sp2)
                        .padding(.bottom, LucakuSpacing.sp8)
                }
            }
            .background(LucakuColor.bg)
            .navigationTitle("Search")
            .searchable(
                text: $viewModel.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search your episodes or a new topic"
            )
            .onSubmit(of: .search) { runSearch() }
            .task {
                guard let token = session.accessToken else { return }
                async let suggestions: Void = viewModel.loadSuggestions(token: token)
                async let existing: Void = viewModel.loadExistingStandingTopics(token: token)
                _ = await (suggestions, existing)
            }
        }
    }

    private func runSearch() {
        guard let token = session.accessToken else { return }
        viewModel.submitSearch(token: token)
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        // Keyed off the query text itself, not just `resultState` — the
        // native `.searchable` clear (X) button and Cancel only ever change
        // the text binding, with no callback of their own, so an empty
        // query always means "show pre-search" regardless of whatever
        // `resultState` was left over from a previous search.
        if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preSearchContent
        } else {
            switch viewModel.resultState {
            case .idle:
                preSearchContent
            case .searching:
                searchingContent
            case .loaded(let result):
                resultsContent(result)
            case .failed(let message):
                failedContent(message)
            }
        }
    }

    // MARK: - Pre-search: recent + suggested

    @ViewBuilder
    private var preSearchContent: some View {
        if !viewModel.recentSearches.isEmpty {
            SearchSectionHeader(title: "Recent searches")
            RecentSearchChipRow(queries: viewModel.recentSearches) { text in
                fillAndSearch(text)
            }
            .padding(.bottom, LucakuSpacing.sp8)
        }

        if !viewModel.suggestions.isEmpty {
            SearchSectionHeader(title: "Suggested for you")
            Text("Based on your interests")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp3)

            VStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, item in
                    SuggestedTopicRow(
                        title: item.headline ?? "Today's shared episode",
                        caption: item.reason,
                        isLast: index == viewModel.suggestions.count - 1,
                        onTap: { fillAndSearch(item.headline ?? item.reason) }
                    )
                }
            }
        }

        if viewModel.recentSearches.isEmpty && viewModel.suggestions.isEmpty {
            EmptySearchPrompt()
        }
    }

    private func fillAndSearch(_ text: String) {
        guard let token = session.accessToken else { return }
        viewModel.fillAndSearch(text, token: token)
    }

    // MARK: - Searching (in progress)

    private var searchingContent: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
            HStack(spacing: 8) {
                ProgressView().tint(LucakuColor.accent)
                Text("Searching your episodes…")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
            }
            SkeletonRow(widths: (0.6, 0.4))
            SkeletonRow(widths: (0.8, 0.4))
            SkeletonRow(widths: (0.6, 0.4))
        }
        .padding(.top, LucakuSpacing.sp4)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: LucakuSpacing.sp3) {
            Text("Couldn't search")
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)
            Text(message)
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { runSearch() }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.top, LucakuSpacing.sp6)
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsContent(_ result: SearchOut) -> some View {
        let rows = episodeResultRows(result)

        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                SearchSectionHeader(title: "From your episodes")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        EpisodeResultRow(row: row, isLast: index == rows.count - 1)
                    }
                }
                .padding(.bottom, LucakuSpacing.sp8)
            }

            if !result.unmatchedRequests.isEmpty {
                SearchSectionHeader(title: "Already tracking this")
                Text("A standing request matched — no episode covering it yet")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.bottom, LucakuSpacing.sp3)
                VStack(spacing: 0) {
                    ForEach(Array(result.unmatchedRequests.enumerated()), id: \.element.id) { index, item in
                        UnmatchedRequestRow(item: item, isLast: index == result.unmatchedRequests.count - 1)
                    }
                }
                .padding(.bottom, LucakuSpacing.sp8)
            }

            if rows.isEmpty && result.unmatchedRequests.isEmpty {
                Text("No matches for \u{201C}\(result.query)\u{201D} in your episodes")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, LucakuSpacing.sp6)
            }

            SearchSectionHeader(title: "Add as a new interest")
            Text("Not something you've asked about yet — start tracking it regularly")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp3)

            AddTopicRow(
                topic: result.query,
                isAdded: viewModel.isTopicAdded(result.query),
                isAdding: viewModel.isTopicAdding(result.query),
                onAdd: { addTopic(result.query) }
            )

            if let error = viewModel.addTopicError {
                Text(error)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(.red)
                    .padding(.top, LucakuSpacing.sp2)
            }
        }
    }

    private func addTopic(_ topic: String) {
        guard let token = session.accessToken else { return }
        Task { await viewModel.addTopicAsInterest(topic, token: token) }
    }

    /// Flattens `SearchOut.episodes` into one row per real hit — a headline
    /// match and/or one row per matched block — matching the mockup's
    /// `.result-row` list where each row is one distinct textual hit, not
    /// one row per episode.
    private func episodeResultRows(_ result: SearchOut) -> [EpisodeResultRow.Row] {
        var rows: [EpisodeResultRow.Row] = []
        for episode in result.episodes {
            if episode.headlineMatch {
                rows.append(.init(
                    id: "\(episode.id)-headline",
                    title: episode.headlineSnippet ?? episode.headline ?? "Untitled episode",
                    fecha: episode.fecha,
                    clock: nil
                ))
            }
            for block in episode.matchedBlocks {
                rows.append(.init(
                    id: block.id,
                    title: block.snippet,
                    fecha: episode.fecha,
                    clock: HomeFormat.clock(block.startS)
                ))
            }
        }
        return rows
    }
}

// MARK: - Shared section header (matches HomeSectionHeader's visual role)

private struct SearchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LucakuTypography.title3)
            .foregroundStyle(LucakuColor.textPrimary)
            .padding(.bottom, LucakuSpacing.sp2)
    }
}

private struct EmptySearchPrompt: View {
    var body: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LucakuColor.textTertiary)
            Text("Search your episodes or track a new topic")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.top, LucakuSpacing.sp8)
    }
}

// MARK: - Recent search chips

private struct RecentSearchChipRow: View {
    let queries: [String]
    var onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: LucakuSpacing.sp2)]

    var body: some View {
        // A simple wrapping flow via LazyVGrid-like adaptive layout keeps
        // this dependency-free; HStack + ScrollView(.horizontal) would clip
        // rows the way the mockup's flex-wrap chip-row never does.
        FlowLayout(spacing: LucakuSpacing.sp2) {
            ForEach(queries, id: \.self) { text in
                Button(action: { onTap(text) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(LucakuColor.textTertiary)
                        Text(text)
                            .font(LucakuTypography.subhead)
                            .foregroundStyle(LucakuColor.textPrimary)
                    }
                    .padding(.horizontal, LucakuSpacing.sp3)
                    .frame(minHeight: 36)
                    .background(
                        Capsule().fill(LucakuColor.surface2)
                    )
                    .overlay(
                        Capsule().strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping flow layout (SwiftUI's `Layout` protocol) — the mockup's
/// `.chip-row { display:flex; flex-wrap:wrap; }` has no single built-in
/// SwiftUI equivalent pre-iOS 16 `Layout`, so this reproduces it exactly:
/// left-to-right, wrapping to a new line when a chip doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
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

// MARK: - Suggested topic row (pre-search)

private struct SuggestedTopicRow: View {
    let title: String
    let caption: String
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: LucakuSpacing.sp3) {
                Circle()
                    .fill(LucakuColor.accentTint)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(LucakuColor.accent)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(LucakuTypography.body)
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: LucakuSpacing.sp2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(LucakuColor.textTertiary)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            }
        }
    }
}

// MARK: - Searching skeleton

private struct SkeletonRow: View {
    let widths: (CGFloat, CGFloat) // fraction of available width, e.g. (0.6, 0.4)

    var body: some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            Circle().fill(LucakuColor.surface2).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4).fill(LucakuColor.surface2)
                        .frame(width: proxy.size.width * widths.0, height: 10)
                }
                .frame(height: 10)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4).fill(LucakuColor.surface2)
                        .frame(width: proxy.size.width * widths.1, height: 10)
                }
                .frame(height: 10)
            }
        }
        .padding(.vertical, LucakuSpacing.sp3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
        }
    }
}

// MARK: - Episode result row

private struct EpisodeResultRow: View {
    struct Row {
        let id: String
        /// May contain the backend's `**bold**`-delimited `ts_headline`
        /// highlight markers around the matched term — stripped for display
        /// (SwiftUI has no cheap HTML-ish inline-bold renderer here without
        /// AttributedString markdown parsing, which the backend's `**`
        /// delimiters aren't valid Markdown for at arbitrary positions).
        let title: String
        let fecha: String
        let clock: String?
    }

    let row: Row
    let isLast: Bool

    private var cleanTitle: String {
        row.title.replacingOccurrences(of: "**", with: "")
    }

    private var metaText: String {
        if let clock = row.clock {
            return "\(row.fecha) episode  ·  \(clock)"
        }
        return "\(row.fecha) episode"
    }

    var body: some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            Circle()
                .fill(LucakuColor.accentTint)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(LucakuColor.accent)
                )
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(cleanTitle)
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(3)
                Text(metaText)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
            }
        }
        .padding(.vertical, LucakuSpacing.sp3)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            }
        }
    }
}

// MARK: - Already-tracking (unmatched standing request) row

private struct UnmatchedRequestRow: View {
    let item: UnmatchedRequestOut
    let isLast: Bool

    private var cleanSnippet: String {
        item.snippet.replacingOccurrences(of: "**", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            Circle()
                .fill(LucakuColor.surface2)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(LucakuColor.textSecondary)
                )
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(cleanSnippet)
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(3)
                Text("Status: \(item.status)")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
            }
        }
        .padding(.vertical, LucakuSpacing.sp3)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            }
        }
    }
}

// MARK: - Add-as-interest row
//
// Anti-ambiguity requirement (per the mockup's own lesson, restated in the
// task): the add affordance is a labeled button ("Add" / "Added", with an
// icon alongside the label), never an icon alone.

private struct AddTopicRow: View {
    let topic: String
    let isAdded: Bool
    let isAdding: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            Circle()
                .fill(LucakuColor.accentTint)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(LucakuColor.accent)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(topic)
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                Text("Start tracking it regularly")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
            }
            Spacer(minLength: LucakuSpacing.sp2)

            Button(action: onAdd) {
                HStack(spacing: 5) {
                    if isAdding {
                        ProgressView().tint(isAdded ? LucakuColor.accentOn : LucakuColor.accent)
                    } else {
                        Image(systemName: isAdded ? "checkmark" : "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(isAdded ? "Added" : "Add")
                        .font(LucakuTypography.subhead.weight(.semibold))
                }
                .foregroundStyle(isAdded ? LucakuColor.accentOn : LucakuColor.accent)
                .padding(.horizontal, LucakuSpacing.sp3)
                .frame(minWidth: 44, minHeight: 36)
                .background(
                    Capsule().fill(isAdded ? LucakuColor.accent : LucakuColor.accentTint)
                )
                .overlay(
                    Capsule().strokeBorder(LucakuColor.accent, lineWidth: isAdded ? 0 : 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isAdded || isAdding)
            .accessibilityLabel(isAdded ? "Added as an interest" : "Add \(topic) as a new interest")
        }
        .padding(.vertical, LucakuSpacing.sp2)
    }
}

#Preview {
    SearchView()
        .environmentObject(SessionStore())
}
