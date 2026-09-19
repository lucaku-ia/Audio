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

    /// "Good morning" / "Good afternoon" / "Good evening" by the device's
    /// local hour — the greeting the top of Home leads with.
    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
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

    /// "personal_finance" -> "Personal finance". Used only as a fallback when
    /// the localized catalogue label for a tag isn't available.
    static func prettyTag(_ tag: String) -> String {
        let spaced = tag.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

// MARK: - Generated cover art

/// Lucaku has no episode artwork (an episode is a voiced briefing, not an
/// album), and Spotify-style Home screens live or die on rich, colourful
/// covers. So covers are generated, deterministically, from a seed string
/// (an interest tag, a topic, an episode headline): the same seed always
/// gets the same gradient and glyph, so a topic looks the same everywhere it
/// appears — its tile, its shelf card, the mini player.
enum LucakuCover {
    /// (dark corner, bright corner) pairs. Saturated on purpose: the app is
    /// dark-first, and these are the only strong colour on screen.
    private static let palette: [(UInt32, UInt32)] = [
        (0x7F1D1D, 0xEF4444), // red
        (0x7C2D12, 0xF97316), // orange
        (0x713F12, 0xEAB308), // amber
        (0x14532D, 0x22C55E), // green
        (0x134E4A, 0x14B8A6), // teal
        (0x1E3A8A, 0x3B82F6), // blue
        (0x312E81, 0x818CF8), // indigo
        (0x581C87, 0xC084FC), // purple
        (0x831843, 0xEC4899), // pink
        (0x1F2937, 0x6B7280), // slate
    ]

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// djb2 — stable across launches (Swift's own `hashValue` is randomized
    /// per process, which would re-colour every cover on every launch).
    private static func stableIndex(for seed: String) -> Int {
        var hash: UInt64 = 5381
        for scalar in seed.lowercased().unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(palette.count))
    }

    static func gradient(for seed: String) -> LinearGradient {
        let pair = palette[stableIndex(for: seed)]
        return LinearGradient(
            colors: [color(pair.0), color(pair.1)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// The cover's darker corner colour — used to tint the mini player.
    static func tint(for seed: String) -> Color {
        color(palette[stableIndex(for: seed)].0)
    }

    /// A glyph that hints at the subject, by keyword (English and Spanish —
    /// topics are the customer's own words). Falls back to a waveform.
    static func symbol(for seed: String) -> String {
        let text = seed.lowercased()
        let table: [([String], String)] = [
            (["market", "econom", "peso", "dolar", "dólar", "financ", "invest", "inflation", "interest rate", "tasa"],
             "chart.line.uptrend.xyaxis"),
            (["tech", "artificial", "software", "crypto", "cripto", "inteligencia"], "cpu"),
            (["sport", "deporte", "football", "fútbol", "futbol", "soccer", "liga", "nba", "tennis", "fc"], "sportscourt"),
            (["science", "ciencia", "space", "espacio", "physics"], "atom"),
            (["health", "salud", "medic", "wellness"], "heart"),
            (["world", "mundo", "international", "global"], "globe"),
            (["politic", "polític", "govern", "gobierno", "congress"], "building.columns"),
            (["climate", "clima", "environment", "ambiente", "energy"], "leaf"),
            (["entertain", "cine", "movie", "music", "música", "culture", "cultura"], "theatermasks"),
            (["local", "colombia", "city", "ciudad"], "mappin.and.ellipse"),
        ]
        for (keywords, symbol) in table where keywords.contains(where: { text.contains($0) }) {
            return symbol
        }
        return "waveform"
    }
}

struct CoverArt: View {
    let seed: String
    var cornerRadius: CGFloat = LucakuRadius.row
    /// Overrides the keyword-derived glyph.
    var glyph: String?

    var body: some View {
        Rectangle()
            .fill(LucakuCover.gradient(for: seed))
            .overlay {
                GeometryReader { proxy in
                    Image(systemName: glyph ?? LucakuCover.symbol(for: seed))
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.44, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.34))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Section header

/// Matches home_v3.html's `.section-head` — a title2 label with an optional
/// trailing link-style button (e.g. "Manage"). Still used by the Interests
/// and Search screens; Home's own shelves use `HomeShelfHeader` below.
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

/// Bold shelf title (Spotify-style) with an optional one-line subtitle and an
/// optional trailing action.
struct HomeShelfHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }
            }
            Spacer(minLength: LucakuSpacing.sp2)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(LucakuTypography.subhead.weight(.semibold))
                        .foregroundStyle(LucakuColor.accent)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(.bottom, LucakuSpacing.sp3)
    }
}

// MARK: - Topic tile (Spotify's "quick access" grid)

/// One of the customer's standing topics, shown as a compact cover + title
/// tile in a two-column grid at the top of Home.
struct TopicTile: View {
    let title: String
    let seed: String
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                CoverArt(seed: seed, cornerRadius: 0)
                    .frame(width: 56, height: 56)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            .frame(height: 56)
            .background(LucakuColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Episode shelf card

/// A square-cover card for a shelf — used for shared-inventory samples
/// ("For you" / "Explore"). Tapping it plays the episode.
struct EpisodeShelfCard: View {
    let title: String
    let subtitle: String
    let seed: String
    let isPlaying: Bool
    var onTap: () -> Void = {}

    // Computed, not a stored `private let`: a private stored property would
    // make this view's synthesized memberwise initializer private too, and
    // HomeView (another file) constructs it.
    private var side: CGFloat { 148 }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                CoverArt(seed: seed, cornerRadius: 8)
                    .frame(width: side, height: side)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(LucakuColor.accent)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(LucakuColor.accentOn)
                                    .offset(x: isPlaying ? 0 : 1)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                            .padding(8)
                    }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)
                Text(subtitle)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero cards

/// Today's episode, when it's ready — the big "Made for you" card.
struct TodayHeroCard: View {
    let headline: String
    let meta: String
    let seed: String
    let isPlaying: Bool
    var onPlay: () -> Void

    var body: some View {
        HStack(spacing: LucakuSpacing.sp4) {
            CoverArt(seed: seed, cornerRadius: 10)
                .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY'S EPISODE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LucakuColor.accent)
                Text(headline)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(meta)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(action: onPlay) {
                    HStack(spacing: 6) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        Text(isPlaying ? "Pause" : "Play")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LucakuColor.accentOn)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(LucakuColor.accent))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(LucakuSpacing.sp3)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }
}

/// Today's episode when it isn't ready: either nothing has been started yet
/// (offer to generate it now — a customer shouldn't have to wait until
/// tomorrow morning to hear the product work), it's being recorded, or the
/// scheduled run is on its way / running long.
struct MakingHeroCard: View {
    let isLate: Bool
    let requestsCount: Int?
    let eta: Date?
    let isGenerating: Bool
    let errorMessage: String?
    var onGenerate: () -> Void

    private var canGenerate: Bool { eta == nil && !isGenerating }

    private var topicsPhrase: String {
        guard let requestsCount else { return "your topics" }
        return "\(requestsCount) topic\(requestsCount == 1 ? "" : "s")"
    }

    private var title: String {
        if isGenerating { return "Recording your episode…" }
        if isLate { return "Running a little long" }
        if eta != nil { return "Your episode is on its way" }
        return "Ready when you are"
    }

    private var subtitle: String {
        if isGenerating {
            return "Researching and voicing \(topicsPhrase) — about a minute or two. You can keep browsing."
        }
        if let eta { return "Ready around \(HomeFormat.shortTime(eta))" }
        return "Lucaku researches \(topicsPhrase) and records them for you. Hear it now instead of waiting for tomorrow morning."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp4) {
            HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
                ZStack {
                    Circle().fill(LucakuColor.accentTintStrong).frame(width: 52, height: 52)
                    if isGenerating || eta != nil {
                        ProgressView().tint(LucakuColor.accent)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(LucakuColor.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(subtitle)
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if canGenerate {
                Button(action: onGenerate) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Generate my episode now")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LucakuColor.accentOn)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(LucakuColor.accent))
                }
                .buttonStyle(.plain)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(.red)
            }
        }
        .padding(LucakuSpacing.sp4)
        .background(
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [LucakuColor.accent.opacity(0.30), LucakuColor.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
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
    /// Whether the shared player is actually playing this row right now —
    /// drives the waveform animation. Comes from the app-root `PlayerViewModel`
    /// (see ContentView.swift), never local/hardcoded state, so this row can't
    /// claim "playing" while the real shared player disagrees.
    var isPlaying: Bool = true
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
                            // Shared with the Player tab's block list (see
                            // Features/Player/WaveformGlyph.swift) — the
                            // "currently playing" indicator is the same
                            // component everywhere, driven by the same
                            // shared PlayerViewModel, not a Home-local copy.
                            WaveformGlyph(isAnimating: isPlaying)
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

/// Horizontal "Recent" shelf — cover tiles for the last few days. Real
/// fields only: a day with an episode shows its headline/duration; a
/// synthesized "no news that day" entry shows a quiet placeholder and isn't
/// tappable (there's nothing to play).
struct RecentShelfView: View {
    let episodes: [RecentEpisodeOut]
    var onSelect: (RecentEpisodeOut) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: LucakuSpacing.sp3) {
                ForEach(episodes) { episode in
                    Button { onSelect(episode) } label: {
                        RecentShelfTile(episode: episode)
                    }
                    .buttonStyle(.plain)
                    .disabled(episode.episodeId == nil)
                }
            }
        }
    }
}

private struct RecentShelfTile: View {
    let episode: RecentEpisodeOut

    private var side: CGFloat { 148 }

    private var isSkipped: Bool { episode.state == "no_news" }
    private var weekdayAndDate: (weekday: String, dateLabel: String) {
        HomeFormat.weekdayAndDate(fromISO: episode.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isSkipped {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LucakuColor.surface)
                        .overlay(
                            Image(systemName: "moon.zzz")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(LucakuColor.textTertiary)
                        )
                } else {
                    CoverArt(seed: episode.headline ?? episode.date, cornerRadius: 8)
                }
            }
            .frame(width: side, height: side)

            Text(isSkipped ? "No news" : (episode.headline ?? "Daily briefing"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSkipped ? LucakuColor.textSecondary : LucakuColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: side, alignment: .leading)
            Text(captionDetail)
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
        }
    }

    private var captionDetail: String {
        var parts = ["\(weekdayAndDate.weekday), \(weekdayAndDate.dateLabel)"]
        if !isSkipped, let minutes = HomeFormat.minutes(episode.durationS) { parts.append(minutes) }
        return parts.joined(separator: " · ")
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
            .padding(.top, LucakuSpacing.sp2)
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
            .padding(.bottom, LucakuSpacing.sp2)
        }
    }
}

// MARK: - Re-entry

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
