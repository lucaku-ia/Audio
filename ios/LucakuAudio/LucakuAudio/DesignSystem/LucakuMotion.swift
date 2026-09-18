//
//  LucakuMotion.swift
//  Lucaku Audio — design tokens
//
//  Source of truth: DESIGN_SPEC_V3.md's "Motion" section — "One house easing
//  curve everywhere: CSS approximation of iOS spring response 0.5s /
//  damping 0.825 — a small, tasteful, single overshoot, never a full
//  bounce," implemented in both mockups as
//  `--ease: cubic-bezier(0.34, 1.2, 0.64, 1)` at `--dur: 380ms`
//  (player_v3.html) / `--ease-house: cubic-bezier(0.34, 1.2, 0.64, 1)` at
//  380ms (home_v3.html) — both files agree exactly on this curve.
//
//  On iOS, the native equivalent of an iOS spring with response 0.5 and
//  damping fraction 0.825 is SwiftUI's `Animation.spring(response:dampingFraction:)`
//  initializer directly — no CSS-to-Swift approximation needed, since both
//  the mockup's CSS curve and this Swift curve are approximating the same
//  underlying UIKit/SwiftUI spring.
//
//  Motion policy (per spec): feedback/hierarchy only, never decorative.
//  Skip motion on frequent, small interactions. This is the ONE house curve
//  — do not introduce additional easing curves elsewhere in the app.
//

import SwiftUI

public enum LucakuMotion {

    /// The one house motion curve: iOS spring response 0.5s / damping fraction 0.825.
    /// Use for all deliberate, hierarchy-communicating transitions (block-row
    /// expand/collapse, mini-player dock/expand, Now Playing sheet presentation).
    public static let house: Animation = .spring(response: 0.5, dampingFraction: 0.825)
}
