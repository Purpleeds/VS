#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

// Game-style building blocks for the menus: a moving backdrop, chunky press-down buttons, glowing tiles, grade
// badges and the player card. SF Symbols only (no emoji); colours from `Theme`.

extension Theme {
    static let backdropTop = Color(red: 0.11, green: 0.06, blue: 0.24)
    static let backdropBottom = Color(red: 0.02, green: 0.03, blue: 0.08)
    static var titleGradient: LinearGradient {
        LinearGradient(colors: [Theme.accent, Theme.violet, Theme.accentSecondary], startPoint: .leading, endPoint: .trailing)
    }

    static func gradeColor(_ grade: Grade) -> Color {
        switch grade {
        case .s: return Theme.gold
        case .a: return Theme.good
        case .b: return Theme.accent
        case .c: return Theme.warn
        case .d, .f: return Theme.bad
        }
    }
}

/// Deep gradient with slow colour blooms and music symbols drifting upward. Still when Reduce Motion is on.
struct GameBackdrop: View {
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyphs = ["music.note", "music.quarternote.3", "waveform", "music.note.list", "music.mic"]
    private static let blooms: [(Color, Double, Double, Double)] = [
        (Theme.violet, 0.2, 0.15, 0.07), (Theme.accent, 0.85, 0.35, 0.05), (Theme.accentSecondary, 0.3, 0.85, 0.06),
    ]

    var body: some View {
        // Copied out so the Canvas renderer doesn't touch main-actor state.
        let still = reduceMotion
        let intensity = self.intensity
        let blooms = Self.blooms
        let glyphCount = Self.glyphs.count
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Theme.backdropTop, Theme.backdropBottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))
                let radius = max(size.width, size.height) * 0.55
                for (color, x, y, speed) in blooms {
                    let center = CGPoint(x: size.width * (x + 0.08 * sin(t * speed * 3)), y: size.height * (y + 0.06 * cos(t * speed * 2)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                        with: .radialGradient(Gradient(colors: [color.opacity(0.28 * intensity), color.opacity(0)]),
                                              center: center, startRadius: 0, endRadius: radius)
                    )
                }
                // Twelve symbols rising slowly, each on its own lane and speed.
                for i in 0..<12 {
                    guard let symbol = context.resolveSymbol(id: i % glyphCount) else { continue }
                    let lane = (Double(i) * 0.618).truncatingRemainder(dividingBy: 1)
                    let speed = 0.012 + 0.008 * Double(i % 4)
                    let rise = (t * speed + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                    let point = CGPoint(x: size.width * (0.05 + 0.9 * lane) + 14 * sin(t * 0.6 + Double(i)),
                                        y: size.height * (1.1 - 1.2 * rise))
                    var glyph = context
                    glyph.opacity = 0.10 * intensity * sin(rise * .pi)
                    glyph.draw(symbol, at: point)
                }
            } symbols: {
                ForEach(0..<Self.glyphs.count, id: \.self) { index in
                    Image(systemName: Self.glyphs[index])
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .tag(index)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A thick, glossy button that sits on a darker "edge" and presses down into it.
struct ChunkyButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var textColor: Color = Theme.backdropBottom
    var height: CGFloat = 58
    var cornerRadius: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(.title3, design: .rounded).weight(.heavy))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity, minHeight: height)
            .background {
                ZStack {
                    shape.fill(LinearGradient(colors: [color.mix(with: .white, by: 0.25), color], startPoint: .top, endPoint: .bottom))
                    shape.inset(by: 3).stroke(.white.opacity(0.28), lineWidth: 1.5).blendMode(.plusLighter)
                }
            }
            .background {
                shape.fill(color.mix(with: .black, by: 0.45)).offset(y: pressed ? 2 : 6)
            }
            .offset(y: pressed ? 4 : 0)
            .shadow(color: color.opacity(pressed ? 0.25 : 0.5), radius: pressed ? 6 : 16, y: 6)
            .padding(.bottom, 6)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: pressed)
    }
}

/// Scales and dims a little while pressed (for tiles and cards).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A menu tile: symbol in a glowing badge, title and a short line.
struct GameTile: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.22))
                Circle().strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 44, height: 44)
            .shadow(color: color.opacity(0.6), radius: 10)
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Theme.surfaceHighlight.opacity(0.9), Theme.surface.opacity(0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [color.opacity(0.7), color.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A letter grade in a coloured, glowing square.
struct GradeBadge: View {
    let grade: Grade
    var size: CGFloat = 30

    var body: some View {
        let color = Theme.gradeColor(grade)
        Text(grade.rawValue)
            .font(.system(size: size * 0.6, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(color.opacity(0.7), lineWidth: 1.5))
            .shadow(color: color.opacity(0.5), radius: 6)
            .accessibilityLabel("Best grade \(grade.rawValue)")
    }
}

/// The game title, in a glowing gradient.
struct NeonTitle: View {
    let text: String
    var size: CGFloat = 46

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(Theme.titleGradient)
            .shadow(color: Theme.violet.opacity(0.7), radius: 18)
            .shadow(color: Theme.accent.opacity(0.35), radius: 4)
    }
}

/// Level ring, experience bar, day streak and best grade.
struct PlayerCard: View {
    let progress: PlayerProgress
    @State private var shown = 0.0

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.surfaceHighlight, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(Theme.titleGradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.accent.opacity(0.6), radius: 6)
                VStack(spacing: -2) {
                    Text("LV")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(progress.level)")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.runs == 0 ? "New singer" : "Level \(progress.level)")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(progress.levelExperience) / \(progress.levelSize) XP")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    Label("\(progress.streakDays)-day streak", systemImage: "flame.fill")
                        .foregroundStyle(progress.streakDays > 0 ? Theme.accentSecondary : Theme.textSecondary)
                    Label("\(progress.runs) runs", systemImage: "music.mic")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if let grade = progress.bestGrade {
                VStack(spacing: 4) {
                    GradeBadge(grade: grade, size: 38)
                    Text("BEST")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.violet.opacity(0.35), lineWidth: 1))
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).delay(0.2)) { shown = max(0.02, progress.levelFraction) }
        }
        .onChange(of: progress.levelFraction) { _, value in
            withAnimation(.easeOut(duration: 0.6)) { shown = max(0.02, value) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Level \(progress.level), \(progress.levelExperience) of \(progress.levelSize) experience, \(progress.streakDays) day streak, \(progress.runs) runs")
    }
}
/// A badge: its symbol on a glowing coin, or dim with a lock while it isn't earned yet.
struct BadgeCoin: View {
    let badge: Badge
    var earned = true
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if earned {
                Circle().fill(LinearGradient(colors: [Theme.gold, Theme.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Circle().fill(Theme.surface)
            }
            Circle().strokeBorder(.white.opacity(earned ? 0.35 : 0.1), lineWidth: 1.5)
            Image(systemName: earned ? badge.symbol : "lock.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(earned ? Theme.backdropBottom : Theme.textSecondary)
        }
        .frame(width: size, height: size)
        .shadow(color: earned ? Theme.gold.opacity(0.5) : .clear, radius: 8)
        .accessibilityElement()
        .accessibilityLabel("\(badge.title)\(earned ? "" : ", locked"): \(badge.detail)")
    }
}
#endif
