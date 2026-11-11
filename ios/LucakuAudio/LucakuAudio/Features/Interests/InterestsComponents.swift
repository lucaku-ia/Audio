import SwiftUI

// Modular building blocks for the Interests tab (screens 6.1-6.4). The
// direction of this screen is still under review (alternatives A-D in the
// spec), so every piece here is self-contained and reusable.

// MARK: - Palette and icons

enum InterestPalette {
    /// The prototype's 10 gradient pairs (dark, bright).
    static let pairs: [(String, String)] = [
        ("7F1D1D", "EF4444"), ("7C2D12", "F97316"), ("713F12", "EAB308"), ("14532D", "22C55E"),
        ("134E4A", "14B8A6"), ("1E3A8A", "3B82F6"), ("312E81", "818CF8"), ("581C87", "C084FC"),
        ("831843", "EC4899"), ("1F2937", "6B7280"),
    ]

    /// 140 degree gradient for a category id (unknown / nil uses the last pair).
    static func gradient(forCategory id: String?) -> LinearGradient {
        let i = id.flatMap { InterestCatalog.order.firstIndex(of: $0) } ?? 9
        let p = pairs[i % 10]
        return LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)],
                              startPoint: UnitPoint(x: 0.17, y: 0.0), endPoint: UnitPoint(x: 0.83, y: 1.0))
    }

    static func symbol(forCategory id: String?) -> String {
        switch id {
        case "lifestyle": return "airplane"
        case "markets": return "chart.line.uptrend.xyaxis"
        case "personal_finance": return "banknote"
        case "technology": return "cpu"
        case "world": return "globe"
        case "local": return "location.fill"
        case "sports": return "soccerball"
        case "health": return "heart.fill"
        case "science": return "atom"
        case "entertainment": return "theatermasks.fill"
        case "politics": return "building.columns.fill"
        case "climate": return "leaf.fill"
        default: return "bookmark.fill"
        }
    }
}

private extension Color {
    init(hex: String) {
        let n = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
}

// MARK: - Type helpers

extension Font {
    static let interestsTitle = Font.system(size: 30, weight: .heavy)
    static let interestsSection = Font.system(size: 22, weight: .heavy)
}

/// Section header: 22pt/800 title with an optional trailing caption.
struct InterestsSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.interestsSection)
                .tracking(-0.3)
                .foregroundStyle(LucakuColor.textPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LucakuColor.textSecondary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tiles

/// Colour tile: bold white name (2 lines), caption, big rotated faded glyph.
struct InterestTile: View {
    let title: String
    var caption: String?
    let categoryId: String?
    var height: CGFloat = 96
    var titleSize: CGFloat = 16
    var checked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Image(systemName: InterestPalette.symbol(forCategory: categoryId))
                    .font(.system(size: caption == nil ? 50 : 58, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
                    .rotationEffect(.degrees(18))
                    .offset(x: 10, y: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: titleSize, weight: .heavy))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.trailing, checked ? 22 : 8)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.82)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.07))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white))
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                        .offset(x: 2, y: -2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(InterestPalette.gradient(forCategory: categoryId))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(checked ? "Following" : "")
    }
}

/// The dashed "+ Add a topic" tile.
struct AddTopicTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                Text("Add a topic").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LucakuColor.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LucakuColor.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips

/// Follow chip: outlined when off ("+"), solid tp-on-bg when on (check).
struct FollowChip: View {
    let label: String
    let isOn: Bool
    var minHeight: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? LucakuColor.bg : LucakuColor.textPrimary)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(minHeight: minHeight)
            .background(Capsule().fill(isOn ? LucakuColor.textPrimary : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? LucakuColor.textPrimary : LucakuColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "Following" : "Not following")
    }
}

/// Wrapping layout for chips.
struct InterestChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Buttons

/// tp-on-bg primary button, 54pt / r16 (spec section 0).
struct InterestsPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LucakuColor.bg)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(LucakuColor.textPrimary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add bar (type or say)

/// Search-style bar, white in dark mode. Typing swaps the mic for Follow.
struct AddTopicBar: View {
    @Binding var text: String
    let isListening: Bool
    let isSubmitting: Bool
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onMic: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && !isListening }
    private var barBg: Color { scheme == .dark ? Color(white: 0.949) : LucakuColor.surface }
    private var barFg: Color { scheme == .dark ? Color(white: 0.067) : LucakuColor.textPrimary }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
            TextField(isListening ? "Listening\u{2026}" : "Add a topic, team or question", text: $text)
                .font(.system(size: 16, weight: .semibold))
                .focused(focus)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .frame(height: 40)
                .disabled(isSubmitting)
            if canSend {
                Button(action: onSubmit) {
                    Group {
                        if isSubmitting { ProgressView().controlSize(.small) } else { Text("Follow") }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(scheme == .dark ? Color.white : LucakuColor.bg)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(scheme == .dark ? Color(white: 0.067) : LucakuColor.textPrimary,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow")
            } else {
                Button(action: onMic) {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isListening ? Color.white : barFg)
                        .frame(width: 38, height: 38)
                        .background(isListening ? LucakuColor.destructive : LucakuColor.fill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop listening" : "Say it")
            }
        }
        .foregroundStyle(barFg)
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(barBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Confirmation line under the bar (6.3), 2 lines max.
struct InterestsConfirmationLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(LucakuColor.textPrimary)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

// MARK: - Undo snackbar

struct UndoSnackbar: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onUndo) {
                Text("Undo")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LucakuColor.bg)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(LucakuColor.textPrimary))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(LucakuColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(LucakuColor.borderSoft, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}

// MARK: - Your episode (delivery settings, 6.1 / 6.4)

struct YourEpisodeCard: View {
    @ObservedObject var viewModel: InterestsViewModel
    let token: String?
    @State private var isOpen = false
    @State private var wheelOpen = false

    private static let lengths: [Int?] = [nil, 5, 10, 15, 20, 30]

    private var timeLabel: String { viewModel.deliveryTime.map(Self.fmt12) ?? "Not set" }

    private var title: String {
        viewModel.deliveryTime.map { "Every day at \(Self.fmt12($0))" } ?? "Choose a delivery time"
    }

    private var lengthLabel: String { viewModel.maxLengthMinutes.map { "\($0) min" } ?? "No limit" }

    private var summary: String {
        let len = viewModel.maxLengthMinutes.map { "Up to \($0) min" } ?? "Any length"
        return "\(len) \u{00B7} \(viewModel.narrationStyle.displayName) style"
    }

    private var note: String {
        guard let t = viewModel.deliveryTime else { return "Pick a time and Lucaku will have your episode ready." }
        return "Research starts an hour before, at \(Self.fmt12(Self.addMinutes(t, -60))). Changes apply from your next episode."
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(LucakuMotion.house) { isOpen.toggle(); if !isOpen { wheelOpen = false } }
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LucakuColor.episodeArt)
                        .frame(width: 40, height: 40)
                        .overlay(Image(systemName: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(LucakuColor.textPrimary).lineLimit(1)
                        Text(summary).font(.system(size: 13)).foregroundStyle(LucakuColor.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LucakuColor.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(minHeight: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                row(icon: "clock", label: "Delivery time", value: timeLabel, chevronRotation: wheelOpen ? 90 : 0) {
                    withAnimation(LucakuMotion.house) { wheelOpen.toggle() }
                }
                if wheelOpen {
                    DatePicker("Delivery time", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(height: 160)
                        .clipped()
                        .padding(.bottom, 6)
                }
                Menu {
                    ForEach(Self.lengths, id: \.self) { m in
                        Button(m.map { "\($0) minutes" } ?? "No limit") {
                            guard let token else { return }
                            Task { await viewModel.setMaxLength(m, token: token) }
                        }
                    }
                } label: {
                    rowLabel(icon: "timer", label: "Max length", value: lengthLabel, chevronRotation: 0)
                }
                Menu {
                    ForEach(NarrationStyle.allCases) { s in
                        Button(s.displayName) {
                            guard let token else { return }
                            Task { await viewModel.setNarrationStyle(s, token: token) }
                        }
                    }
                } label: {
                    rowLabel(icon: "person.wave.2", label: "Narration style", value: viewModel.narrationStyle.displayName, chevronRotation: 0)
                }

                if viewModel.settingsEdited {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                        Text("Applies tomorrow").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.top, 8)
                    .padding(.leading, 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .padding(.leading, 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(LucakuMotion.house, value: viewModel.settingsEdited)
    }

    private func row(icon: String, label: String, value: String, chevronRotation: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon: icon, label: label, value: value, chevronRotation: chevronRotation) }
            .buttonStyle(.plain)
    }

    private func rowLabel(icon: String, label: String, value: String, chevronRotation: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(LucakuColor.icon)
                .frame(width: 40)
            Text(label).font(.system(size: 16)).foregroundStyle(LucakuColor.textPrimary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 15)).foregroundStyle(LucakuColor.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LucakuColor.textTertiary)
                .rotationEffect(.degrees(chevronRotation))
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5) }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let (h, m) = Self.parse(viewModel.deliveryTime ?? "07:00")
                return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let token else { return }
                viewModel.setDeliveryTime(String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 0), token: token)
            }
        )
    }

    private static func parse(_ hhmm: String) -> (Int, Int) {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 7, p.count > 1 ? p[1] : 0)
    }

    static func fmt12(_ hhmm: String) -> String {
        let (h, m) = parse(hhmm)
        return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h >= 12 ? "PM" : "AM")
    }

    static func addMinutes(_ hhmm: String, _ delta: Int) -> String {
        let (h, m) = parse(hhmm)
        let t = ((h * 60 + m + delta) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
