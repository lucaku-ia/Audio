import SwiftUI

/// "What should we change?" — the shared "Not quite" feedback sheet (screens
/// spec 4.7). Used by the player and, with different `detail` copy, by news
/// stories: feedback lives in one place.
///
/// Multi-select reasons, an optional written suggestion, and *Report a
/// problem*. Present with `.sheet` (it sets its own detents).
struct FeedbackSheetView: View {
    /// Secondary line under the title, e.g. `About “Story”. Lucaku uses this
    /// to shape your next episodes.`
    let detail: String
    let onSend: (_ options: [String], _ suggestion: String) -> Void
    let onReport: () -> Void

    static let options = [
        "Too long", "Too short", "Not relevant to me",
        "Needs more detail", "Too technical", "Stop covering this topic",
    ]

    @State private var selection: Set<String> = []
    @State private var suggestion = ""
    @FocusState private var suggestionFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should we change?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)

                PlayerFlowLayout(spacing: 8) {
                    ForEach(Self.options, id: \.self) { option in
                        optionChip(option)
                    }
                }

                Text("Any suggestion? (optional)")
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                TextField("e.g. Start with what it means for my savings", text: $suggestion, axis: .vertical)
                    .lineLimit(3...3)
                    .focused($suggestionFocused)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(12)
                    .background(LucakuColor.bg, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(LucakuColor.border, lineWidth: 1))

                // Accent: this is the sheet's primary action.
                Button {
                    onSend(Self.options.filter(selection.contains), suggestion)
                } label: {
                    Text("Send feedback")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LucakuColor.accentOn)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(LucakuColor.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selection.isEmpty)
                .opacity(selection.isEmpty ? 0.4 : 1)
                .padding(.top, 16)

                Button(action: onReport) {
                    Label("Something's wrong? Report a problem", systemImage: "flag")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LucakuColor.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    private func optionChip(_ option: String) -> some View {
        let on = selection.contains(option)
        return Button {
            if on { selection.remove(option) } else { selection.insert(option) }
        } label: {
            HStack(spacing: 6) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                }
                Text(option).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(on ? LucakuColor.fill : Color.clear))
            .overlay(Capsule().stroke(on ? LucakuColor.textPrimary : LucakuColor.border, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Minimal wrapping layout (iOS 16+) for chip rows.
struct PlayerFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
