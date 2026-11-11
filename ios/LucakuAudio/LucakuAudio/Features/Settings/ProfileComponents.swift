import SwiftUI
import UIKit

// MARK: - Shared building blocks for the Profile tab (screens spec 7-8)
//
// Section 0 rules honoured here: accent is never used for selections or
// toggles (neutral `tp` selections, `switchOn` for switches), icons are
// white-on-gray in dark mode (`LucakuColor.icon` on `fill`), primary buttons
// are solid `tp` on `bg`, 54 pt tall with a 16 pt radius.

/// Re-enables the interactive swipe-back gesture when the navigation bar is
/// hidden (Profile sub-pages draw their own "< Profile" back button).
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }
}

/// Destinations pushed from the Profile root.
enum ProfileRoute: Hashable {
    case history
    case downloads
    case notifications
    case appearance
    case account
    case help
    case delivery
    case timezone
    case maxLength
}

/// Scaffold for every Profile sub-page: "< Profile" back button, large title,
/// optional two-line-max caption, and the status-bar fade.
struct ProfilePage<Content: View>: View {
    let title: String
    var subtitle: String?
    var backTitle: String = "Profile"
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StatusBarFadeAnchor()
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text(backTitle)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(backTitle)")

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .padding(.top, 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 6)
                }
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140) // clears the mini player + tab bar
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .statusBarFade()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 40 pt rounded icon tile: icon white on gray in dark, brand teal on tint in light.
struct ProfileIconTile: View {
    let symbol: String
    var tint: Color = LucakuColor.icon
    var background: Color = LucakuColor.iconTile

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Flat list row used on Profile pages (icon tile, title, optional caption/value,
/// chevron). Rows are at least 56 pt tall.
struct ProfileRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var value: String?
    var destructive = false
    var showsChevron = false
    var showsSpinner = false

    var body: some View {
        HStack(spacing: 14) {
            ProfileIconTile(
                symbol: symbol,
                tint: destructive ? LucakuColor.destructive : LucakuColor.icon,
                background: destructive ? LucakuColor.destructive.opacity(0.12) : LucakuColor.iconTile
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(destructive ? LucakuColor.destructive : LucakuColor.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            if showsSpinner { ProgressView() }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LucakuColor.textTertiary)
            }
        }
        .frame(minHeight: 56)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Hairline separator between flat rows.
struct ProfileSeparator: View {
    var body: some View {
        Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5)
    }
}

/// 13 pt uppercase section label (spec section 0).
struct ProfileSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(LucakuColor.textSecondary)
            .padding(.top, 22)
            .padding(.bottom, 4)
    }
}

/// Footnote under a group (max two lines).
struct ProfileNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(LucakuColor.textSecondary)
            .lineLimit(2)
            .padding(.top, 7)
            .padding(.horizontal, 4)
    }
}

/// Rounded surface container for grouped rows (cards 16 pt).
struct ProfileCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous))
    }
}

/// One row inside a `ProfileCard` (48+ pt, label left, value/trailing right).
struct ProfileCardRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var destructive = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(destructive ? LucakuColor.destructive : LucakuColor.icon)
                    .frame(width: 24)
            }
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(destructive ? LucakuColor.destructive : LucakuColor.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// Separator inset to the card's text edge.
struct ProfileCardDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5).padding(.leading, inset)
    }
}

/// Primary action: solid `tp` on `bg`, 54 pt, 16 pt radius.
struct ProfilePrimaryButton: View {
    let title: String
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(LucakuColor.bg)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(LucakuColor.bg)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(LucakuColor.textPrimary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

/// Pill option (lead time, etc.): selected = solid `tp` on `bg`, others outlined.
struct ProfilePill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .medium))
                .lineLimit(1)
                .foregroundStyle(selected ? LucakuColor.bg : LucakuColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(selected ? LucakuColor.textPrimary : Color.clear))
                .overlay(Capsule().stroke(selected ? Color.clear : LucakuColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Neutral-toned switch (uses the spec's `swon` token, never the accent).
struct ProfileSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(LucakuColor.switchOn)
    }
}

/// Title + two-line detail with a switch, used on the notifications page.
struct ProfileToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            ProfileSwitch(isOn: $isOn)
        }
    }
}

// MARK: - Formatting helpers

enum ProfileFormat {
    /// "07:00" -> "7:00 AM"
    static func time12(_ hhmm: String?) -> String {
        guard let hhmm, let date = parser.date(from: hhmm) else { return "Off" }
        return display.string(from: date)
    }

    static func time12(_ date: Date) -> String { display.string(from: date) }

    /// Shifts an "HH:mm" wall-clock string by `minutes` (wraps past midnight).
    static func shifted(_ hhmm: String?, byMinutes minutes: Int) -> String? {
        guard let hhmm, let date = parser.date(from: hhmm) else { return nil }
        let moved = date.addingTimeInterval(TimeInterval(minutes * 60))
        return parser.string(from: moved)
    }

    static func minutesLabel(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        return "\(max(1, Int((Double(seconds) / 60).rounded()))) min"
    }

    static func dayLabel(_ isoDate: String) -> String {
        guard let date = isoParser.date(from: isoDate) else { return isoDate }
        if Calendar.current.isDateInToday(date) { return "Today" }
        return dayFormatter.string(from: date)
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d"
        return f
    }()
}
