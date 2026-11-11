import SwiftUI

/// "What should we change?" — the single "Not quite" feedback sheet (screens
/// spec 4.7), used by the player and by news stories.
///
/// Multi-select reasons, an optional written suggestion, and *Report a
/// problem*. Present with `.sheet` (it sets its own detents).
struct FeedbackSheet: View {
    /// The story or episode the feedback is about.
    let subject: String
    /// What the feedback shapes. Stories: how news is written; player: next episodes.
    var purpose = "how it writes your news"
    let onSend: (_ options: [String], _ suggestion: String) -> Void
    let onReport: () -> Void

    static let options = [
        "Too long", "Too short", "Not relevant to me",
        "Needs more detail", "Too technical", "Stop covering this topic",
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var suggestion = ""

    private var canSend: Bool {
        !selection.isEmpty || !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should we change?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text("About \u{201C}\(subject)\u{201D}. Lucaku uses this to shape \(purpose).")
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)

                FlowLayout(spacing: 8) {
                    ForEach(Self.options, id: \.self) { option in
                        optionChip(option)
                    }
                }

                Text("Any suggestion? (optional)")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                TextField("e.g. Start with what it means for my savings", text: $suggestion, axis: .vertical)
                    .lineLimit(3...3)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.bg))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LucakuColor.border, lineWidth: 1))

                Button {
                    onSend(Self.options.filter(selection.contains), suggestion)
                    dismiss()
                } label: {
                    Text("Send feedback")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LucakuColor.bg)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LucakuColor.textPrimary))
                }
                .buttonStyle(.plain)
                .opacity(canSend ? 1 : 0.4)
                .disabled(!canSend)
                .padding(.top, 16)

                Button {
                    onReport()
                    dismiss()
                } label: {
                    Label("Something's wrong? Report a problem", systemImage: "flag")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, LucakuSpacing.sp4)
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
