//
//  LucakuColor.swift
//  Lucaku Audio — design tokens
//
//  Source of truth: /tmp/lucaku_design/player_v3.html, the `:root` token block
//  (light values) and its `@media (prefers-color-scheme: dark)` block (dark
//  values). These are the exact 16 tokens requested for the app's palette;
//  they are named and valued identically to that file's CSS custom
//  properties (`--bg`, `--surface`, `--surface-2`, `--border`,
//  `--border-soft`, `--text-primary`, `--text-secondary`, `--text-tertiary`,
//  `--accent`, `--accent-tint`, `--accent-tint-strong`, `--accent-on`,
//  `--scrim`, `--amb-1`, `--amb-2`, `--page-bg`).
//
//  NOTE ON SOURCE DIVERGENCE: home_v3.html defines a *different* token set
//  under the same conceptual roles (its own amber/brass `--accent` via
//  `hsl(32 62% 38%)`, a different `--bg` of #F4F4F2, `--bg-elevated` instead
//  of `--surface`, `--divider`/`--divider-strong` instead of `--border`, no
//  `--amb-1`/`--amb-2`/`--page-bg` at all). It was NOT reconciled with
//  player_v3.html's palette. Because the token list requested for this file
//  maps name-for-name onto player_v3.html's set, player_v3.html is treated
//  as canonical here. See TOKENS_README.md for the full discrepancy list —
//  whoever integrates this should confirm with design which palette is
//  meant to ship before this ships to production.
//
//  Every color below switches automatically between light and dark using
//  SwiftUI's dynamic-color pattern (UIColor trait-collection closure bridged
//  to Color), matching the system appearance exactly the way the mockups'
//  `prefers-color-scheme: dark` media query does in a browser.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum LucakuColor {

    // MARK: - Dynamic color helper

    /// Builds a `Color` that resolves to `light` in light mode and `dark` in dark mode,
    /// following the system appearance automatically (SwiftUI's `Color(light:dark:)` pattern).
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
        #else
        return Color(light)
        #endif
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> UIColor {
        UIColor(red: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }

    // MARK: - Tokens

    /// --bg — #F2F2F7 light / #000000 dark
    public static let bg = dynamic(
        light: rgb(242, 242, 247),
        dark: rgb(0, 0, 0)
    )

    /// --surface — #FFFFFF light / #1C1C1E dark
    public static let surface = dynamic(
        light: rgb(255, 255, 255),
        dark: rgb(28, 28, 30)
    )

    /// --surface-2 — #FFFFFF light / #262629 dark
    public static let surface2 = dynamic(
        light: rgb(255, 255, 255),
        dark: rgb(38, 38, 41)
    )

    /// --border — rgba(60,60,67,0.29) light / rgba(84,84,88,0.6) dark
    public static let border = dynamic(
        light: rgb(60, 60, 67, 0.29),
        dark: rgb(84, 84, 88, 0.6)
    )

    /// --border-soft — rgba(60,60,67,0.16) light / rgba(84,84,88,0.38) dark
    public static let borderSoft = dynamic(
        light: rgb(60, 60, 67, 0.16),
        dark: rgb(84, 84, 88, 0.38)
    )

    /// --text-primary — #1C1C1E light / #F2F2F2 dark
    public static let textPrimary = dynamic(
        light: rgb(28, 28, 30),
        dark: rgb(242, 242, 242)
    )

    /// --text-secondary — rgba(60,60,67,0.68) light / rgba(235,235,245,0.64) dark
    public static let textSecondary = dynamic(
        light: rgb(60, 60, 67, 0.68),
        dark: rgb(235, 235, 245, 0.64)
    )

    /// --text-tertiary — rgba(60,60,67,0.35) light / rgba(235,235,245,0.35) dark
    public static let textTertiary = dynamic(
        light: rgb(60, 60, 67, 0.35),
        dark: rgb(235, 235, 245, 0.35)
    )

    /// --accent — #1E647E light / #74B9D1 dark
    public static let accent = dynamic(
        light: rgb(30, 100, 126),
        dark: rgb(116, 185, 209)
    )

    /// --accent-tint — rgba(30,100,126,0.09) light / rgba(116,185,209,0.14) dark
    public static let accentTint = dynamic(
        light: rgb(30, 100, 126, 0.09),
        dark: rgb(116, 185, 209, 0.14)
    )

    /// --accent-tint-strong — rgba(30,100,126,0.16) light / rgba(116,185,209,0.24) dark
    public static let accentTintStrong = dynamic(
        light: rgb(30, 100, 126, 0.16),
        dark: rgb(116, 185, 209, 0.24)
    )

    /// --accent-on — #FFFFFF light / #05262F dark
    /// (Foreground color to place on top of a solid `accent` fill.)
    public static let accentOn = dynamic(
        light: rgb(255, 255, 255),
        dark: rgb(5, 38, 47)
    )

    /// --scrim — rgba(0,0,0,0.32) light / rgba(0,0,0,0.5) dark
    public static let scrim = dynamic(
        light: rgb(0, 0, 0, 0.32),
        dark: rgb(0, 0, 0, 0.5)
    )

    /// --amb-1 — #cdd7d9 light / #17282c dark
    /// (Now Playing ambient backdrop gradient, stop 1 — muted, desaturated, never oversaturated.)
    public static let ambient1 = dynamic(
        light: rgb(0xCD, 0xD7, 0xD9),
        dark: rgb(0x17, 0x28, 0x2C)
    )

    /// --amb-2 — #b7c3c9 light / #1f3339 dark
    /// (Now Playing ambient backdrop gradient, stop 2.)
    public static let ambient2 = dynamic(
        light: rgb(0xB7, 0xC3, 0xC9),
        dark: rgb(0x1F, 0x33, 0x39)
    )

    // MARK: - Spec v2 tokens (screens spec, section 0)

    /// fill — segmented track, chips
    public static let fill = dynamic(
        light: rgb(118, 118, 128, 0.12),
        dark: rgb(118, 118, 128, 0.24)
    )

    /// seg — the *selected* segment; must stay visible against `fill`
    public static let segSelected = dynamic(
        light: rgb(255, 255, 255),
        dark: rgb(0x63, 0x63, 0x66)
    )

    /// glow — login top-centre radial glow; rgba(14,116,144,.32) dark / rgba(30,100,126,.16) light
    public static let glow = dynamic(
        light: rgb(30, 100, 126, 0.16),
        dark: rgb(14, 116, 144, 0.32)
    )

    /// ico — icon glyph colour (white-on-gray in dark, never light blue on black)
    public static let icon = dynamic(
        light: rgb(30, 100, 126),
        dark: rgb(242, 242, 242)
    )

    /// icobg — icon tile background
    public static let iconTile = dynamic(
        light: rgb(30, 100, 126, 0.09),
        dark: rgb(118, 118, 128, 0.24)
    )

    /// swon — switch on
    public static let switchOn = dynamic(
        light: rgb(30, 100, 126),
        dark: rgb(0x3E, 0x8E, 0xA8)
    )

    /// red — destructive actions and errors
    public static let destructive = dynamic(
        light: rgb(255, 59, 48),
        dark: rgb(255, 69, 58)
    )

    /// Episode art gradient: #1E3A8A → #0E7490 at 150°.
    public static let episodeArt = LinearGradient(
        colors: [Color(red: 0x1E / 255, green: 0x3A / 255, blue: 0x8A / 255),
                 Color(red: 0x0E / 255, green: 0x74 / 255, blue: 0x90 / 255)],
        startPoint: UnitPoint(x: 0.25, y: 0.0),
        endPoint: UnitPoint(x: 0.75, y: 1.0)
    )

    /// --page-bg — #E4E4E9 light / #0b0b0d dark
    /// (Backdrop behind the phone-frame mockup itself; the outermost page background.)
    public static let pageBg = dynamic(
        light: rgb(0xE4, 0xE4, 0xE9),
        dark: rgb(0x0B, 0x0B, 0x0D)
    )
}
