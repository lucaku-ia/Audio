import SwiftUI

/// Interests screen — matches `/tmp/lucaku_design/search_interests_v3.html`'s
/// `#page-interests` (the "INTERESTS VIEW" block): a "Standing interests"
/// list (topic, cadence label, mute switch, edit chevron revealing cadence
/// chips + a destructive "Remove interest" action) followed by an
/// "Explore more" section of add-as-interest rows.
///
/// This file only builds the screen itself — no tab bar / navigation wiring.
/// It's expected to be hosted from whatever `Tab` case the concurrent tab-bar
/// restructuring work adds for Interests (see ContentView.swift, untouched
/// here per that work's own scope).
///
/// Real vs. stubbed, precisely:
/// - Standing interests list, "Explore more" list, add, and remove: REAL —
///   backed by `GET /onboarding/interest_options`, `GET /onboarding/state`,
///   and `PATCH /onboarding/interests` (see InterestsViewModel.swift).
/// - Cadence label ("Every weekday morning", "Daily", etc.) and the
///   mute/pause switch: STUBBED. `OnboardingState` has no cadence field and
///   no paused/active flag — there's nothing server-side to read or write.
///   Rendered visually per the mockup (so the layout the design shipped is
///   still legible) but disabled, exactly like Settings' Membership row
///   ("visible, disabled, labelled Coming soon" — see SettingsView.swift).
struct InterestsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = InterestsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.loadState {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load Interests",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .loaded:
                    interestsList
                }
            }
            .navigationTitle("Interests")
            .task { await load() }
            .refreshable { await load() }
            .tint(LucakuColor.accent)
            .alert("Couldn't update interests", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    // MARK: - List

    private var interestsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                standingSection
                Rectangle()
                    .fill(LucakuColor.borderSoft)
                    .frame(height: 1)
                    .padding(.vertical, LucakuSpacing.sp6)
                exploreSection
            }
            .padding(.horizontal, LucakuSpacing.sp4)
            .padding(.top, LucakuSpacing.sp2)
            .padding(.bottom, LucakuSpacing.sp8)
        }
        .background(LucakuColor.bg)
    }

    // MARK: - Standing interests

    private var standingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Standing interests")
            Text("Lucaku researches these topics for your daily episode")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp3)
                .padding(.top, -LucakuSpacing.sp2)

            if viewModel.standingInterests.isEmpty {
                Text("No standing interests yet — add one below.")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.vertical, LucakuSpacing.sp4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.standingInterests.enumerated()), id: \.element.id) { index, interest in
                        StandingInterestRow(
                            interest: interest,
                            isExpanded: viewModel.expandedInterestId == interest.id,
                            isLast: index == viewModel.standingInterests.count - 1,
                            isPending: viewModel.pendingIds.contains(interest.id),
                            onToggleExpand: { viewModel.toggleExpanded(interest.id) },
                            onRemove: { await remove(interest.id) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Explore more

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Explore more")
            Text("Add another topic from Lucaku's interest catalogue")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp3)
                .padding(.top, -LucakuSpacing.sp2)

            if viewModel.exploreOptions.isEmpty {
                Text("You've added every available topic.")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.vertical, LucakuSpacing.sp4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.exploreOptions.enumerated()), id: \.element.id) { index, interest in
                        ExploreRow(
                            interest: interest,
                            isLast: index == viewModel.exploreOptions.count - 1,
                            isPending: viewModel.pendingIds.contains(interest.id),
                            onAdd: { await add(interest.id) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }

    private func add(_ id: String) async {
        guard let token = session.accessToken else { return }
        await viewModel.addInterest(id: id, token: token)
    }

    private func remove(_ id: String) async {
        guard let token = session.accessToken else { return }
        await viewModel.removeInterest(id: id, token: token)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
        )
    }
}

// MARK: - Standing interest row

/// Matches the mockup's `.interest-row` + `.interest-expand` pair: an icon,
/// the topic label, a cadence caption, a mute/pause `.ios-switch`, and an
/// edit chevron that reveals cadence chips + a destructive remove chip.
///
/// The switch and the cadence chips are disabled stubs (see InterestsView's
/// doc comment) — only the "Remove interest" action and the row's own
/// expand/collapse are live.
private struct StandingInterestRow: View {
    let interest: InterestsViewModel.Interest
    let isExpanded: Bool
    let isLast: Bool
    let isPending: Bool
    let onToggleExpand: () -> Void
    let onRemove: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LucakuSpacing.sp3) {
                InterestIconView(interestId: interest.id)

                VStack(alignment: .leading, spacing: 1) {
                    Text(interest.label)
                        .font(LucakuTypography.body)
                        .foregroundStyle(LucakuColor.textPrimary)
                    // STUB: no cadence field exists on OnboardingState — see
                    // InterestsViewModel.swift's doc comment. Shown as a
                    // neutral, honest caption instead of a fabricated
                    // schedule like the mockup's "Every weekday morning".
                    Text("Standing interest")
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }

                Spacer(minLength: LucakuSpacing.sp2)

                if isPending {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    // STUB toggle: always "on" and disabled. There is no
                    // paused/active flag anywhere server-side to read or
                    // write, so this deliberately does not pretend to
                    // persist a mute/pause state (see module doc comment).
                    // TODO: wire to a real per-interest pause/resume
                    // endpoint once one exists.
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .disabled(true)
                        .opacity(0.4)
                        .accessibilityLabel("Pause this interest — not available yet")

                    Button(action: onToggleExpand) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LucakuColor.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(interest.label)")
                }
            }
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) {
                if !isExpanded && !isLast {
                    Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
                }
            }

            if isExpanded {
                HStack(spacing: LucakuSpacing.sp2) {
                    // STUB: cadence isn't a real, editable field (see doc
                    // comment above) — shown disabled rather than omitted
                    // outright, so the control's eventual home is visible.
                    StubChip(title: "Cadence — coming soon")
                    Spacer(minLength: 0)
                    Button {
                        Task { await onRemove() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .regular))
                            Text("Remove interest")
                                .font(LucakuTypography.subhead)
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, LucakuSpacing.sp3)
                        .frame(minHeight: 36)
                        .overlay(
                            Capsule().strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, LucakuSpacing.sp3)
                .overlay(alignment: .bottom) {
                    if !isLast {
                        Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(LucakuMotion.house, value: isExpanded)
    }
}

private struct StubChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LucakuTypography.subhead)
            .foregroundStyle(LucakuColor.textTertiary)
            .padding(.horizontal, LucakuSpacing.sp3)
            .frame(minHeight: 36)
            .overlay(
                Capsule().strokeBorder(LucakuColor.border, lineWidth: 1)
            )
    }
}

// MARK: - Explore row

/// Matches the mockup's `.explore-row` — an icon, the topic label, and an
/// explicit text "+ Add" button (never icon-only — the mockup's file header
/// draws this exact lesson from an "Audible-ambiguity" precedent). Tapping
/// Add is a real, wired `PATCH /onboarding/interests` call.
private struct ExploreRow: View {
    let interest: InterestsViewModel.Interest
    let isLast: Bool
    let isPending: Bool
    let onAdd: () async -> Void

    var body: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            InterestIconView(interestId: interest.id, tinted: false)

            Text(interest.label)
                .font(LucakuTypography.body)
                .foregroundStyle(LucakuColor.textPrimary)

            Spacer(minLength: LucakuSpacing.sp2)

            Button {
                Task { await onAdd() }
            } label: {
                HStack(spacing: 5) {
                    if isPending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("Add")
                        .font(LucakuTypography.subhead.weight(.semibold))
                }
                .foregroundStyle(LucakuColor.accent)
                .padding(.horizontal, LucakuSpacing.sp3)
                .frame(minWidth: 44, minHeight: 36)
                .background(Capsule().fill(LucakuColor.accentTint))
                .overlay(Capsule().strokeBorder(LucakuColor.accent, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isPending)
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            }
        }
    }
}

// MARK: - Interest icon

/// A small, deterministic SF Symbol per known catalogue id (mirroring the
/// mockup's per-topic glyphs), falling back to a generic bookmark glyph for
/// any id the client doesn't recognize — so a future catalogue addition
/// degrades gracefully instead of crashing or leaving a blank circle.
private struct InterestIconView: View {
    let interestId: String
    var tinted: Bool = true

    private var systemImage: String {
        switch interestId {
        case "markets", "personal_finance": return "chart.line.uptrend.xyaxis"
        case "technology": return "cpu"
        case "world": return "globe"
        case "local": return "mappin.and.ellipse"
        case "sports": return "sportscourt"
        case "health": return "heart"
        case "science": return "atom"
        case "entertainment": return "theatermasks"
        case "politics": return "building.columns"
        case "climate": return "leaf"
        default: return "bookmark"
        }
    }

    var body: some View {
        Circle()
            .fill(tinted ? LucakuColor.accentTint : LucakuColor.surface2)
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(tinted ? LucakuColor.accent : LucakuColor.textSecondary)
            )
    }
}

#Preview {
    InterestsView()
        .environmentObject(SessionStore())
}
