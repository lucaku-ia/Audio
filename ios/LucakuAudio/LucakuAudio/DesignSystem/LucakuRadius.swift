//
//  LucakuRadius.swift
//  Lucaku Audio — design tokens
//
//  Source of truth: player_v3.html's `:root` block —
//    --r-chip:10px;   small chips / pills
//    --r-row:8px;     small thumbnails / tinted rows, ~40-56pt
//    --r-card:16px;   floating bars / medium cards
//    --r-sheet:20px;  large sheets / big surfaces, ~120pt+
//  matching the spec's "corner radius scales by element size/context, never
//  uniform" rule (DESIGN_SPEC_V3.md, Spacing / touch targets section).
//
//  NOTE ON SOURCE DIVERGENCE: home_v3.html defines an analogous but
//  differently-scaled and differently-named radius set for the same
//  conceptual roles: `--r-sm: 8px` (list rows), `--r-md: 12px` (elevated
//  "currently playing" row), `--r-lg: 18px` (hero-scale artwork). Its
//  small-radius value (8px) matches player_v3's `--r-row`, but its
//  medium/large values (12px / 18px) do NOT match player_v3's `--r-card`
//  (16px) / `--r-sheet` (20px). Since the requested token names
//  (chip/row/card/sheet) map onto player_v3.html's naming, this file uses
//  player_v3.html's values as canonical. See TOKENS_README.md for the full
//  comparison.
//

import CoreGraphics

public enum LucakuRadius {

    /// --r-chip — 10px. Small chips / pills (e.g. speed selector, filter chips).
    public static let chip: CGFloat = 10

    /// --r-row — 8px. Small thumbnails / tinted list rows, ~40–56pt elements.
    public static let row: CGFloat = 8

    /// --r-card — 16px. Floating bars / medium cards (e.g. mini-player, summary cards).
    public static let card: CGFloat = 16

    /// --r-sheet — 20px. Large sheets / big surfaces, ~120pt+ (e.g. Now Playing sheet).
    public static let sheet: CGFloat = 20
}
