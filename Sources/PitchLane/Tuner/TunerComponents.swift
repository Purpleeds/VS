#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Horizontal -50...+50 cent gauge. `cents == nil` hides the needle.
struct CentsNeedle: View {
    let cents: Double?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                ZStack {
                    Capsule()
                        .fill(Theme.surface)
                    Rectangle()
                        .fill(Theme.good.opacity(0.18))
                        .frame(width: width * 0.2)
                    ForEach([-50.0, -25, -10, 0, 10, 25, 50], id: \.self) { tick in
                        Rectangle()
                            .fill(Theme.grid.opacity(tick == 0 ? 0.9 : 0.35))
                            .frame(width: tick == 0 ? 2 : 1, height: tick == 0 ? height : height * 0.45)
                            .offset(x: CGFloat(tick / 50) * (width / 2 - 2))
                    }
                    if let cents {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(for: cents))
                            .frame(width: 5, height: height + 6)
                            .offset(x: CGFloat(max(-50, min(50, cents)) / 50) * (width / 2 - 3))
                            .animation(.linear(duration: 0.06), value: cents)
                    }
                }
            }
            .frame(height: 30)
            HStack {
                Text("-50").frame(maxWidth: .infinity, alignment: .leading)
                Text(cents.map { String(format: "%+.0f¢", $0) } ?? "–")
                    .foregroundStyle(cents.map(Self.color(for:)) ?? Theme.textSecondary)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text("+50").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tuning")
        .accessibilityValue(cents.map { c in
            let rounded = Int(c.rounded())
            return rounded == 0 ? "in tune" : "\(abs(rounded)) cents \(rounded > 0 ? "sharp" : "flat")"
        } ?? "No pitch")
        .accessibilityAddTraits(.updatesFrequently)
    }

    static func color(for cents: Double) -> Color {
        switch abs(cents) {
        case ..<10: return Theme.good
        case ..<25: return Theme.warn
        default: return Theme.bad
        }
    }
}

/// Labelled horizontal bar 0...1 with an optional threshold marker.
struct MeterBar: View {
    let title: String
    let value: Double
    let marker: Double?
    let valueText: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
                        .animation(.linear(duration: 0.06), value: value)
                    if let marker {
                        Rectangle()
                            .fill(Theme.textPrimary.opacity(0.7))
                            .frame(width: 2)
                            .offset(x: geo.size.width * CGFloat(marker) - 1)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

/// Scrolling pitch line over the last few seconds, with a semitone grid.
struct PitchGraph: View {
    let history: PitchHistory
    let range: ClosedRange<Double>
    let accidentals: Accidentals

    var body: some View {
        Canvas { context, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0, size.width > 0, size.height > 0 else { return }
            let now = history.latestTime ?? 0
            let labelWidth: CGFloat = 34
            let plotWidth = size.width - labelWidth
            func y(_ midi: Double) -> CGFloat { size.height * CGFloat(1 - (midi - range.lowerBound) / span) }
            func x(_ time: Double) -> CGFloat { labelWidth + plotWidth * CGFloat(1 - (now - time) / history.duration) }

            // Semitone grid; C lines and labels stronger.
            let lowest = Int(range.lowerBound.rounded(.up))
            let highest = Int(range.upperBound.rounded(.down))
            if lowest <= highest {
                for note in lowest...highest {
                    let pitchClass = ((note % 12) + 12) % 12
                    let isC = pitchClass == 0
                    let isNatural = [0, 2, 4, 5, 7, 9, 11].contains(pitchClass)
                    var line = Path()
                    line.move(to: CGPoint(x: labelWidth, y: y(Double(note))))
                    line.addLine(to: CGPoint(x: size.width, y: y(Double(note))))
                    context.stroke(line, with: .color(Theme.grid.opacity(isC ? 0.45 : (isNatural ? 0.18 : 0.08))), lineWidth: isC ? 1 : 0.5)
                    if isC || (isNatural && span <= 16) {
                        let label = Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals))
                            .font(.system(size: 10, weight: isC ? .bold : .regular, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        context.draw(label, at: CGPoint(x: 4, y: y(Double(note))), anchor: .leading)
                    }
                }
            }

            // Pitch line, broken at unvoiced frames and gaps.
            var path = Path()
            var penDown = false
            var lastTime = -Double.infinity
            var lastPoint: CGPoint?
            for point in history.points {
                guard let midi = point.midi else {
                    penDown = false
                    continue
                }
                let p = CGPoint(x: x(point.time), y: y(min(range.upperBound, max(range.lowerBound, midi))))
                if penDown && point.time - lastTime < 0.035 {
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                }
                penDown = true
                lastTime = point.time
                lastPoint = p
            }
            context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if let lastPoint, penDown {
                let dot = Path(ellipseIn: CGRect(x: lastPoint.x - 5, y: lastPoint.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(Theme.accent))
            }
        }
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Pitch over the last five seconds")
    }
}
#endif
