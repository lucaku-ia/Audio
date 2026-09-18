//
//  LucakuTypography.swift
//  Lucaku Audio — design tokens
//
//  Source of truth: DESIGN_SPEC_V3.md's "Type scale (Apple HIG, confirmed
//  exact values)" section, cross-checked against both player_v3.html's and
//  home_v3.html's `:root` blocks (`--fs-*` / `--lh-*` custom properties),
//  which agree exactly on every size and line height. Uses the system font
//  (San Francisco) via SwiftUI's `.system(size:weight:)`, never a custom or
//  downloaded font, per the spec's "system-ui, -apple-system" stack note
//  (that stack is a web fallback chain standing in for SF Pro; on-device
//  this is simply the system font).
//
//  Weight policy (per spec): Regular everywhere except a small, named set of
//  roles that the mockups render Semibold (title3, headline, and the
//  "currently playing" row's promoted text) — one Semibold accent per
//  screen, never Light/Thin.
//

import SwiftUI

public enum LucakuTypography {

    // MARK: - Font (HIG type-scale roles)

    /// Large Title — 34pt / 41pt line height, Regular
    public static let largeTitle = Font.system(size: 34, weight: .regular)

    /// Title 1 — 28pt / 34pt line height, Regular
    public static let title1 = Font.system(size: 28, weight: .regular)

    /// Title 2 — 22pt / 28pt line height, Regular
    public static let title2 = Font.system(size: 22, weight: .regular)

    /// Title 3 — 20pt / 25pt line height, Semibold (per spec's Title3 weight)
    public static let title3 = Font.system(size: 20, weight: .semibold)

    /// Headline — 17pt / 22pt line height, Semibold
    public static let headline = Font.system(size: 17, weight: .semibold)

    /// Body — 17pt / 22pt line height, Regular
    public static let body = Font.system(size: 17, weight: .regular)

    /// Callout — 16pt / 21pt line height, Regular
    public static let callout = Font.system(size: 16, weight: .regular)

    /// Subhead — 15pt / 20pt line height, Regular
    public static let subhead = Font.system(size: 15, weight: .regular)

    /// Footnote — 13pt / 18pt line height, Regular
    public static let footnote = Font.system(size: 13, weight: .regular)

    /// Caption 1 — 12pt / 16pt line height, Regular
    public static let caption1 = Font.system(size: 12, weight: .regular)

    /// Caption 2 — 11pt / 13pt line height, Regular
    public static let caption2 = Font.system(size: 11, weight: .regular)

    // MARK: - Line heights (pt)

    /// Matching `--lh-*` values from the mockups, exposed for manual
    /// `.lineSpacing(_:)` calculations where SwiftUI's default line height
    /// for the system font doesn't already match the HIG value.
    public enum LineHeight {
        public static let largeTitle: CGFloat = 41
        public static let title1: CGFloat = 34
        public static let title2: CGFloat = 28
        public static let title3: CGFloat = 25
        public static let headline: CGFloat = 22
        public static let body: CGFloat = 22
        public static let callout: CGFloat = 21
        public static let subhead: CGFloat = 20
        public static let footnote: CGFloat = 18
        public static let caption1: CGFloat = 16
        public static let caption2: CGFloat = 13
    }

    // MARK: - Point sizes (pt)

    /// Matching `--fs-*` values from the mockups, exposed for cases where
    /// callers need the raw number (e.g. custom `UIFont` bridging).
    public enum PointSize {
        public static let largeTitle: CGFloat = 34
        public static let title1: CGFloat = 28
        public static let title2: CGFloat = 22
        public static let title3: CGFloat = 20
        public static let headline: CGFloat = 17
        public static let body: CGFloat = 17
        public static let callout: CGFloat = 16
        public static let subhead: CGFloat = 15
        public static let footnote: CGFloat = 13
        public static let caption1: CGFloat = 12
        public static let caption2: CGFloat = 11
    }
}

// MARK: - View convenience

public extension View {
    /// Applies a Lucaku type-scale role's font AND its HIG line height
    /// (via `.lineSpacing`, added on top of the font's natural leading) in
    /// one call, e.g. `.lucakuFont(.body, lineHeight: LucakuTypography.LineHeight.body)`.
    func lucakuFont(_ font: Font, lineHeight: CGFloat, pointSize: CGFloat) -> some View {
        self
            .font(font)
            .lineSpacing(max(0, lineHeight - pointSize))
    }
}
