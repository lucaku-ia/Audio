//
//  LucakuSpacing.swift
//  Lucaku Audio — design tokens
//
//  Source of truth: player_v3.html's `:root` block —
//  `--sp-1:4px; --sp-2:8px; --sp-3:12px; --sp-4:16px; --sp-6:24px; --sp-8:32px; --sp-12:48px;`
//  (an 8px-base spacing scale used as an internal consistency tool per
//  DESIGN_SPEC_V3.md, not a claimed Apple rule). home_v3.html defines the
//  same 7 values under the same names and additionally defines
//  `--sp-5: 20px`, which player_v3.html does not have; it is included below
//  as `sp5` for completeness since it is real, sourced token data, but note
//  it only appears in one of the two mockups.
//
//  Naming convention: the numeric suffix is the multiplier of the 4pt base
//  unit (sp1 = 4 * 1 = 4pt, sp6 = 4 * 6 = 24pt, sp12 = 4 * 12 = 48pt),
//  exactly mirroring the mockups' `--sp-N` naming. There is intentionally no
//  sp7/sp9/sp10/sp11 — the scale skips values the mockups never use.
//

import CoreGraphics

public enum LucakuSpacing {

    /// --sp-1 — 4pt
    public static let sp1: CGFloat = 4

    /// --sp-2 — 8pt
    public static let sp2: CGFloat = 8

    /// --sp-3 — 12pt
    public static let sp3: CGFloat = 12

    /// --sp-4 — 16pt
    public static let sp4: CGFloat = 16

    /// --sp-5 — 20pt (home_v3.html only; not present in player_v3.html)
    public static let sp5: CGFloat = 20

    /// --sp-6 — 24pt
    public static let sp6: CGFloat = 24

    /// --sp-8 — 32pt
    public static let sp8: CGFloat = 32

    /// --sp-12 — 48pt
    public static let sp12: CGFloat = 48
}
