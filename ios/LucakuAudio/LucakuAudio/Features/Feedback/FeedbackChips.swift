import SwiftUI

/// The Useful / Not quite chips (screens spec 3.8 / 4.7). Shared by news
/// stories and the player so feedback lives in one place. Selected state is
/// neutral: `selectedFill` background with `selectedText` content. The player
/// overrides the colours with its artwork-derived theme.
struct FeedbackChips: View {
    let rating: StoryRating?
    var onUseful: () -> Void
    var onNotQuite: () -> Void
    var text: Color = LucakuColor.textPrimary
    var fill: Color = LucakuColor.fill
    var selectedFill: Color = LucakuColor.textPrimary
    var selectedText: Color = LucakuColor.bg

    var body: some View {
        HStack(spacing: 8) {
            chip("Useful", icon: "hand.thumbsup", on: rating == .up, action: onUseful)
                .accessibilityLabel("Mark story as useful")
            chip("Not quite", icon: "hand.thumbsdown", on: rating == .down, action: onNotQuite)
                .accessibilityLabel("Not quite right: tell us what to change")
        }
    }

    private func chip(_ label: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "\(icon).fill" : icon).font(.system(size: 15))
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(on ? selectedText : text)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(on ? selectedFill : fill))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
