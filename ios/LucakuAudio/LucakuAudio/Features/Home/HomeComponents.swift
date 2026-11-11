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
    /// (dark corner, bright corner) pairs, all drawn from one muted family
    /// around the brand accent (#1E647E).
    ///
    /// This replaced a ten-hue saturated set (red/orange/amber/green/teal/
    /// blue/indigo/purple/pink/slate) that was justified as "the app is
    /// dark-first, and these are the only strong colour on screen". The app
    /// follows the device's light/dark setting now, and the founder's
    /// reaction to landing on the purple was unambiguous. It also contradicted
    /// the approved design spec on two counts: the accent is meant to be the
    /// only strong colour, and generated art is meant to read "muted,
    /// desaturated... ambient, not celebratory".
    ///
    /// Covers still differ per topic — enough to tell two episodes apart at a
    /// glance — but they now read as one product rather than a paint box.
    private static let palette: [(UInt32, UInt32)] = [
        (0x0E3B4C, 0x1E647E), // brand teal
        (0x123E45, 0x2C7A85), // deep cyan
        (0x14352F, 0x2E6B5C), // pine
        (0x1E2F3D, 0x3E6076), // slate blue
        (0x25333B, 0x4C6A78), // blue grey
        (0x1F2A3C, 0x415A7A), // deep navy
        (0x2B2A26, 0x6B6558), // stone
        (0x1F2124, 0x4A4F55), // graphite
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

