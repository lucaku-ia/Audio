import SwiftUI

// MARK: - Story colour

/// Per-story colour for the player (screens spec 4: "the colour follows the
/// current story"). The 10 gradient pairs are the prototype's `PALETTE`; the
/// pair is picked by a stable djb2 hash of the story title, same as the
/// prototype's `pidx`, so a story keeps its colour across launches.
enum StoryPalette {
    private static let pairs: [(dark: UInt32, light: UInt32)] = [
        (0x7F1D1D, 0xEF4444), (0x7C2D12, 0xF97316), (0x713F12, 0xEAB308),
        (0x14532D, 0x22C55E), (0x134E4A, 0x14B8A6), (0x1E3A8A, 0x3B82F6),
        (0x312E81, 0x818CF8), (0x581C87, 0xC084FC), (0x831843, 0xEC4899),
        (0x1F2937, 0x6B7280),
    ]

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func colors(for seed: String) -> (deep: Color, bright: Color) {
        var hash: UInt64 = 5381
        for scalar in seed.lowercased().unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let pair = pairs[Int(hash % UInt64(pairs.count))]
        return (color(pair.dark), color(pair.light))
    }

    static func gradient(for seed: String) -> LinearGradient {
        let c = colors(for: seed)
        return LinearGradient(colors: [c.deep, c.bright], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Theme

/// Now Playing colours. Light stays white with a soft wash of the story
/// colour; dark is a deep background lit by it (screens spec 4, "Theme").
/// Icons and controls are white on gray in dark, never light blue.
struct PlayerTheme {
    let isDark: Bool
    let base: Color
    let fg: Color
    let fg2: Color
    let fg3: Color
    let fgBody: Color
    let track: Color
    let fill: Color
    let tick: Color
    let buttonBg: Color
    let buttonFg: Color
    let card: Color
    let separator: Color
    let chip: Color
    let ok: Color
    let artShadow: Color
    let playedLine: Color
    let upcomingLine: Color
    let wash: LinearGradient

    init(colorScheme: ColorScheme, story seed: String) {
        let c = StoryPalette.colors(for: seed)
        let dark = colorScheme == .dark
        isDark = dark
        if dark {
            base = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)
            fg = .white
            fg2 = .white.opacity(0.72)
            fg3 = .white.opacity(0.6)
            fgBody = .white.opacity(0.88)
            track = .white.opacity(0.26)
            fill = .white
            tick = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)
            buttonBg = .white
            buttonFg = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)
            card = .white.opacity(0.08)
            separator = .white.opacity(0.14)
            chip = .white.opacity(0.14)
            ok = Color(red: 0x7E / 255, green: 0xE2 / 255, blue: 0xA8 / 255)
            artShadow = .black.opacity(0.45)
            playedLine = .white.opacity(0.62)
            upcomingLine = .black.opacity(0.55)
            wash = LinearGradient(
                stops: [
                    .init(color: c.bright.opacity(0.55), location: 0),
                    .init(color: c.deep.opacity(0.85), location: 0.38),
                    .init(color: Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255).opacity(0.96), location: 0.78),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            base = .white
            fg = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
            fg2 = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72)
            fg3 = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.62)
            fgBody = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.86)
            track = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.16)
            fill = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
            tick = .white
            buttonBg = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
            buttonFg = .white
            card = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
            separator = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.14)
            chip = Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255).opacity(0.12)
            ok = Color(red: 0x1E / 255, green: 0x7A / 255, blue: 0x45 / 255)
            artShadow = .black.opacity(0.16)
            playedLine = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.5)
            upcomingLine = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.36)
            wash = LinearGradient(
                stops: [
                    .init(color: c.bright.opacity(0.2), location: 0),
                    .init(color: c.bright.opacity(0.07), location: 0.34),
                    .init(color: c.bright.opacity(0), location: 0.62),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        // Transcript card: tinted with the story colour in dark, a faint wash in light.
        transcriptCard = dark
            ? AnyShapeStyle(LinearGradient(colors: [c.bright.opacity(0.95), c.deep.opacity(0.98)],
                                           startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
            : AnyShapeStyle(c.bright.opacity(0.12))
    }

    let transcriptCard: AnyShapeStyle
}

// MARK: - Story copy

extension BlockOut {
    /// Two-sentence gist for the "In this episode" list (max 2 lines in UI).
    /// TODO(backend): blocks carry no dedicated 2-line summary field yet; until
    /// the API returns one this is the first two sentences of the script, and
    /// the view clamps to two lines.
    var gist: String {
        let sentences = script
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return "" }
        return sentences.prefix(2).map { $0 + "." }.joined(separator: " ")
    }

    var durationS: Int { max(0, endS - startS) }
}

// MARK: - Art

/// Episode art (gradient token `LucakuColor.episodeArt`) with a faint glyph.
struct PlayerArt: View {
    var seed: String
    var cornerRadius: CGFloat

    var body: some View {
        Rectangle()
            .fill(LucakuColor.episodeArt)
            .overlay {
                GeometryReader { proxy in
                    Image(systemName: LucakuCover.symbol(for: seed))
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.44, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.32))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
