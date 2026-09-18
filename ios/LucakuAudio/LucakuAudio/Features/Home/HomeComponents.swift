import SwiftUI

// MARK: - Formatting helpers

/// Duration/date formatting shared by Home's subviews. Every value passed in
/// here comes from the real `HomeOut` response — nothing here invents data,
/// it only formats what the API returned.
enum HomeFormat {
    static func minutes(_ seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "\(minutes) min"
    }

    static func clock(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Thursday, September 17" — today's date, since this hero is always
    /// describing *today's* episode. The mockup hardcodes a sample date the
    /// same way; here it's the real current date rather than a fixture.
    static var todayHeadline: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    /// RecentEpisodeOut.date is a plain ISO "YYYY-MM-DD" string from the
    /// backend. Parsed defensively — falls back to the raw string if the
    /// backend ever changes format, rather than crashing the row.
    static func weekdayAndDate(fromISO iso: String) -> (weekday: String, dateLabel: String) {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = inputFormatter.date(from: iso) else {
            return (iso, iso)
        }
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        return (weekdayFormatter.string(from: date), dateFormatter.string(from: date))
    }
}

// MARK: - Section header

/// Matches home_v3.html's `.section-head` — a title2 label with an optional
/// trailing link-style button (e.g. "Manage").
struct HomeSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(LucakuTypography.title2)
                .foregroundStyle(LucakuColor.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(LucakuTypography.callout)
                        .foregroundStyle(LucakuColor.accent)
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.bottom, LucakuSpacing.sp3)
    }
}

// MARK: - Block row (the core "block list, not a timeline" pattern)

/// One row in the block list. Plain (topic + duration) for every block
/// except the currently-playing one, which gets the tinted background, the
/// animated waveform indicator, and its own sub-progress bar — per
/// DESIGN_SPEC_V3.md's "THE core pattern" section. Tapping a row expands a
/// subordinate "go deeper / ask a follow-up" disclosure using
/// `LucakuMotion.house`.
struct HomeBlockRowView: View {
    /// nil for the currently-playing row (it gets the waveform instead of a
    /// number), otherwise the row's 1-based position.
    let number: Int?
    let title: String
    /// e.g. "Now playing · 1:38 of 4:12" for the current row, or a plain
    /// duration like "5:30" for any other row.
    let metaText: String
    let isCurrent: Bool
    /// 0...1, only meaningful (and only shown) when `isCurrent` is true.
    let subprogress: Double?
    let isExpanded: Bool
    let isLast: Bool
    var onTap: () -> Void = {}
    var onGoDeeper: () -> Void = {}
    var onAskFollowUp: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: LucakuSpacing.sp3) {
                    Group {
                        if isCurrent {
                            AnimatedWaveform(size: .regular, isAnimating: true)
                        } else if let number {
                            Text("\(number)")
                                .font(LucakuTypography.footnote)
                                .foregroundStyle(LucakuColor.textTertiary)
                        }
                    }
                    .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(LucakuTypography.body)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(LucakuColor.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(metaText)
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                    }

                    Spacer(minLength: LucakuSpacing.sp2)

                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(LucakuColor.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .padding(.vertical, LucakuSpacing.sp3)
                .padding(.horizontal, LucakuSpacing.sp3)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) {
                if !isCurrent && !isLast {
                    Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
                }
            }

            if isCurrent, let subprogress {
                GeometryReader { proxy in
                    Capsule()
                        .fill(LucakuColor.border)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(LucakuColor.accent)
                                .frame(width: max(0, proxy.size.width * subprogress))
                        }
                }
                .frame(height: 2.5)
                .padding(.horizontal, LucakuSpacing.sp3)
                .padding(.bottom, LucakuSpacing.sp3)
            }

            if isExpanded {
                HStack(spacing: LucakuSpacing.sp2) {
                    ChipButton(title: "Go deeper", systemImage: "plus", isOnTint: isCurrent, action: onGoDeeper)
                    ChipButton(title: "Ask a follow-up", systemImage: nil, isOnTint: isCurrent, action: onAskFollowUp)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, LucakuSpacing.sp3)
                .padding(.bottom, LucakuSpacing.sp3)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isCurrent ? LucakuColor.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous))
        .animation(LucakuMotion.house, value: isExpanded)
    }
}

private struct ChipButton: View {
    let title: String
    let systemImage: String?
    let isOnTint: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .regular))
                }
                Text(title).font(LucakuTypography.subhead)
            }
            .foregroundStyle(LucakuColor.textSecondary)
            .padding(.horizontal, LucakuSpacing.sp3)
            .frame(minHeight: 36)
            .background(
                Capsule().fill(isOnTint ? LucakuColor.bg : LucakuColor.surface)
            )
            .overlay(
                Capsule().strokeBorder(isOnTint ? Color.clear : LucakuColor.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recent shelf

/// Horizontal "Recent" shelf — ScrollView + LazyHStack per the mockup's
/// `.shelf` pattern. Real fields only: `RecentEpisodeOut` has no per-day
/// topic count, so each tile shows duration/style (when there's a real
/// episode) or "No briefing" (for a synthesized empty-day entry) rather than
/// inventing a topic count the API doesn't provide.
struct RecentShelfView: View {
    let episodes: [RecentEpisodeOut]
    var onSelect: (RecentEpisodeOut) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: LucakuSpacing.sp3) {
                ForEach(episodes) { episode in
                    Button { onSelect(episode) } label: {
                        RecentShelfTile(episode: episode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct RecentShelfTile: View {
    let episode: RecentEpisodeOut

    private var isSkipped: Bool { episode.state == "no_news" }
    private var weekdayAndDate: (weekday: String, dateLabel: String) {
        HomeFormat.weekdayAndDate(fromISO: episode.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp2) {
            RoundedRectangle(cornerRadius: LucakuRadius.sheet, style: .continuous)
                .fill(isSkipped ? LucakuColor.borderSoft : LucakuColor.surface2)
                .frame(width: 104, height: 104)
                .overlay(
                    Text(weekdayAndDate.weekday)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isSkipped ? LucakuColor.textTertiary : LucakuColor.textSecondary)
                )

            if isSkipped {
                Text("No briefing")
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
                Text("weekend skip")
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
            } else {
                Text(weekdayAndDate.dateLabel)
                    .font(LucakuTypography.caption1)
                    .fontWeight(.regular)
                    .foregroundStyle(LucakuColor.textPrimary)
                Text(captionDetail)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
            }
        }
        .frame(width: 104, alignment: .leading)
    }

    private var captionDetail: String {
        var parts: [String] = []
        if let minutes = HomeFormat.minutes(episode.durationS) { parts.append(minutes) }
        if let style = episode.style { parts.append(style) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

// MARK: - Your interests

/// DESIGN_SPEC_V3.md's "Your interests" section. NOTE ON DATA: there is no
/// interests-management endpoint wired up anywhere in this scaffold's
/// `APIClient` (no cadence, no per-interest toggle) — `HomeOut` only carries
/// `shared_inventory`, each entry already tagged with a real `reason` string
/// derived server-side from the customer's onboarding interests (see
/// home.py's `_derive_shared_inventory`). Rather than fabricate cadence text
/// ("Every weekday morning") the mockup shows, this renders the row using
/// only the two real fields available (`reason`, `headline`) in the same
/// visual shape as the mockup's `.interest-row`. The trailing chevron and
/// "Manage" link are visual/structural placeholders — wire them to a real
/// interests-management endpoint once one exists (TODO).
struct InterestsSectionView: View {
    let items: [SharedInventoryOut]
    var onManage: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Your interests", actionTitle: "Manage", action: onManage)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    InterestRow(item: item, isLast: index == items.count - 1)
                }
            }
        }
    }
}

private struct InterestRow: View {
    let item: SharedInventoryOut
    let isLast: Bool

    var body: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.reason)
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textPrimary)
                if let headline = item.headline {
                    Text(headline)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: LucakuSpacing.sp2)
            // TODO: wire to a real per-interest edit/manage flow once an
            // interests-management endpoint exists; presentational only today.
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(LucakuColor.textTertiary)
                .frame(width: 44, height: 44)
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
            }
        }
    }
}

// MARK: - Empty ("caught up") state

/// The `empty_day` banner state — real, server-derived (see home.py:
/// `job.status == JobStatus.empty` → `BannerOut(state="empty_day")`), not a
/// fabricated UI trigger. Matches home_v3.html's `#view-empty`: calm,
/// non-apologetic copy, a manual re-check affordance, and a revisit-recent
/// list — plus the scaffold's real "Request something for today" action,
/// which the mockup doesn't depict but which is the one genuinely wired
/// empty_day action in the real API (`POST /home/request-today`).
struct EmptyCaughtUpView: View {
    let recent: [RecentEpisodeOut]
    @Binding var requestText: String
    let isSubmitting: Bool
    let submitError: String?
    var onCheckNow: () -> Void
    var onSubmitRequest: () -> Void
    var onSelectRecent: (RecentEpisodeOut) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: LucakuSpacing.sp2) {
                Text("You're caught up.")
                    .font(LucakuTypography.title1)
                    .foregroundStyle(LucakuColor.textPrimary)
                Text("Nothing new right now. Your next briefing arrives tomorrow morning.")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(.bottom, LucakuSpacing.sp5)

                Button(action: onCheckNow) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Check now")
                    }
                    .font(LucakuTypography.callout)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.horizontal, LucakuSpacing.sp4)
                    .frame(minHeight: 44)
                    .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, LucakuSpacing.sp6)
            .padding(.bottom, LucakuSpacing.sp4)

            Rectangle().fill(LucakuColor.borderSoft).frame(height: 1)
                .padding(.vertical, LucakuSpacing.sp6)

            VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
                Text("Request something for today")
                    .font(LucakuTypography.headline)
                    .foregroundStyle(LucakuColor.textPrimary)
                TextField("What do you want to know about today?", text: $requestText, axis: .vertical)
                    .font(LucakuTypography.body)
                    .padding(LucakuSpacing.sp3)
                    .background(
                        RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous)
                            .strokeBorder(LucakuColor.border, lineWidth: 1)
                    )
                Button(action: onSubmitRequest) {
                    HStack {
                        if isSubmitting { ProgressView().tint(LucakuColor.accentOn) }
                        Text("Request for today")
                    }
                    .font(LucakuTypography.callout.weight(.semibold))
                    .foregroundStyle(LucakuColor.accentOn)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(LucakuColor.accent))
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.7 : 1)
                if let submitError {
                    Text(submitError)
                        .font(LucakuTypography.caption1)
                        .foregroundStyle(.red)
                }
            }
            .padding(.bottom, LucakuSpacing.sp6)

            if !recent.isEmpty {
                HomeSectionHeader(title: "Revisit recent")
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, episode in
                        RevisitRow(episode: episode, isLast: index == recent.count - 1) {
                            onSelectRecent(episode)
                        }
                    }
                }
            }
        }
    }
}

private struct RevisitRow: View {
    let episode: RecentEpisodeOut
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LucakuSpacing.sp3) {
                Text(HomeFormat.weekdayAndDate(fromISO: episode.date).dateLabel)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.headline ?? "No news that day")
                        .font(LucakuTypography.body)
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(2)
                    if let minutes = HomeFormat.minutes(episode.durationS) {
                        Text(minutes)
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                    }
                }
                Spacer(minLength: LucakuSpacing.sp2)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(LucakuColor.textTertiary)
                    .frame(width: 44, height: 44)
            }
            .padding(.vertical, LucakuSpacing.sp2)
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

// MARK: - In-progress hero (making / late)

/// Not covered by the approved mockup (home_v3.html only shows "ready" and
/// "empty_day"), but `making`/`late` are real states `GET /api/home` can
/// return (see home.py's `_derive_banner`). Built as a reasonable extension
/// of the same visual language (tokens, type scale, spacing) rather than
/// left as the scaffold's plain `LabeledContent` list. Flagged in the PR as
/// a SwiftUI-idiom translation, not a pixel-verified mockup match.
struct HeroInProgressView: View {
    let isLate: Bool
    let requestsCount: Int?
    let eta: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
            HStack(spacing: LucakuSpacing.sp3) {
                ZStack {
                    Circle().fill(LucakuColor.accentTint).frame(width: 56, height: 56)
                    ProgressView().tint(LucakuColor.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLate ? "Running a little long" : "Today's episode is being put together")
                        .font(LucakuTypography.headline)
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(subtitle)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }
            }
        }
        .padding(.vertical, LucakuSpacing.sp2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let requestsCount { parts.append("\(requestsCount) request\(requestsCount == 1 ? "" : "s") in progress") }
        if let eta { parts.append("ready around \(HomeFormat.shortTime(eta))") }
        return parts.isEmpty ? "Check back soon" : parts.joined(separator: " · ")
    }
}

/// `re_entry` — the customer has no active standing requests at all. Also
/// not depicted in the mockup; a minimal, honest bridge to the one real
/// action available (creating a one-off request via the same
/// `POST /home/request-today` endpoint empty_day uses).
struct HeroReEntryView: View {
    @Binding var requestText: String
    let isSubmitting: Bool
    let submitError: String?
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp3) {
            Text("Nothing lined up yet")
                .font(LucakuTypography.title1)
                .foregroundStyle(LucakuColor.textPrimary)
            Text("Add a topic or question and Lucaku will start researching it for your next briefing.")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
                .frame(maxWidth: 300, alignment: .leading)

            TextField("What should Lucaku follow?", text: $requestText, axis: .vertical)
                .font(LucakuTypography.body)
                .padding(LucakuSpacing.sp3)
                .background(
                    RoundedRectangle(cornerRadius: LucakuRadius.row, style: .continuous)
                        .strokeBorder(LucakuColor.border, lineWidth: 1)
                )
            Button(action: onSubmit) {
                HStack {
                    if isSubmitting { ProgressView().tint(LucakuColor.accentOn) }
                    Text("Add request")
                }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.accentOn)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(LucakuColor.accent))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.7 : 1)
            if let submitError {
                Text(submitError).font(LucakuTypography.caption1).foregroundStyle(.red)
            }
        }
        .padding(.vertical, LucakuSpacing.sp2)
    }
}
