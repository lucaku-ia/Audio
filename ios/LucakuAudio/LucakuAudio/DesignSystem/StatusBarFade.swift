//
//  StatusBarFade.swift
//  Lucaku Audio — design system
//
//  Screens spec section 0: content never sits under the status bar. At the top
//  of a scroll view there is no strip; once content scrolls beneath the status
//  bar a solid-to-transparent fade (~84 pt) appears, and disappears again at
//  the top. Applies to every tab, onboarding and the player.
//
//  Usage (iOS 17 compatible, so scroll offset is read via a preference):
//
//      ScrollView {
//          StatusBarFadeAnchor()          // first child of the scroll content
//          ...
//      }
//      .statusBarFade()
//

import SwiftUI

private enum StatusBarFadeSpace {
    static let name = "lucaku.statusBarFade"
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Zero-height marker; place as the first child of the scroll content.
public struct StatusBarFadeAnchor: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ScrollOffsetKey.self,
                value: proxy.frame(in: .named(StatusBarFadeSpace.name)).minY
            )
        }
        .frame(height: 0)
    }
}

private struct StatusBarFadeModifier: ViewModifier {
    let background: Color
    let height: CGFloat

    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: StatusBarFadeSpace.name)
            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                let scrolled = offset < -1
                if scrolled != isScrolled {
                    withAnimation(.easeOut(duration: 0.2)) { isScrolled = scrolled }
                }
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [background, background.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .ignoresSafeArea(edges: .top)
                    .opacity(isScrolled ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

public extension View {
    /// Apply to a `ScrollView`. `background` should match the screen
    /// background; pass the player background colour in the player.
    func statusBarFade(background: Color = LucakuColor.bg, height: CGFloat = 84) -> some View {
        modifier(StatusBarFadeModifier(background: background, height: height))
    }
}
