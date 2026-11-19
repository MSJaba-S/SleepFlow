import SwiftUI

/// Circular Sleep Score with an animated fill and a rolling number.
struct ScoreRing: View {
    let score: Int?
    var size: CGFloat = 200
    var lineWidth: CGFloat = 16
    var caption: LocalizedStringKey = "Sleep Score"

    @State private var progress: Double = 0
    @State private var displayed: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceRaised, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.scoreGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                if score != nil {
                    Text(verbatim: "\(displayed)")
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(displayed)))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text(verbatim: "–")
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(lineWidth)
        }
        .frame(width: size, height: size)
        .onAppear { animate() }
        .onChange(of: score) { _, _ in animate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep Score"))
        .accessibilityValue(score.map { Text("\($0) of 100") } ?? Text("No score yet"))
        .accessibilityIdentifier("scoreRing")
    }

    private func animate() {
        let value = score ?? 0
        let target = Double(value) / 100
        progress = 0
        displayed = 0
        if reduceMotion {
            progress = target
            displayed = value
        } else {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.85).delay(0.15)) {
                progress = target
                displayed = value
            }
        }
    }
}
