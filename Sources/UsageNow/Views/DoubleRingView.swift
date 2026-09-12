import SwiftUI

struct DoubleRingView: View {
    let title: String
    let innerProgress: Double
    let outerProgress: Double
    let innerColor: Color
    let outerColor: Color
    let innerAccessibilityLabel: String
    let outerAccessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ring(progress: outerProgress, diameter: 132, lineWidth: 12, color: outerColor)
                .accessibilityLabel(outerAccessibilityLabel)
            ring(progress: innerProgress, diameter: 98, lineWidth: 10, color: innerColor)
                .accessibilityLabel(innerAccessibilityLabel)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(width: 140, height: 140)
    }

    private func ring(progress: Double, diameter: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
        let warning = progress >= 0.9 && !progress.isNaN
        let strokeColor = warning ? Color.red : color
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(strokeColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
        }
    }
}
