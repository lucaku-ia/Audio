import SwiftUI

/// The small animated waveform glyph shown only on the currently-playing
/// block row's leading edge (player_v3.html's `.wave` — 4 bars with staggered
/// scaleY animation). Per DESIGN_SPEC_V3.md's motion policy this is the one
/// "small, frequent" animation the spec explicitly doesn't ask us to skip,
/// since it IS the primary "this block is playing" signal (a real, sourced
/// pattern from Apple Podcasts/Overcast style chapter lists).
struct WaveformGlyph: View {
    var isAnimating: Bool
    var color: Color = LucakuColor.accent

    private let barHeights: [CGFloat] = [6, 14, 9, 13]
    @State private var animate = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(barHeights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(color)
                    .frame(width: 2.5, height: barHeights[index])
                    .scaleEffect(y: animate ? 1.0 : 0.4, anchor: .bottom)
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(index) * 0.15)
                            : .default,
                        value: animate
                    )
            }
        }
        .frame(width: 16, height: 16, alignment: .bottom)
        .onAppear { animate = isAnimating }
        .onChange(of: isAnimating) { _, newValue in animate = newValue }
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformGlyph(isAnimating: true)
        WaveformGlyph(isAnimating: false)
    }
    .padding()
}
