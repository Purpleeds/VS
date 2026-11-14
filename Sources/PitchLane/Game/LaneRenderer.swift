#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

extension NoteRating {
    var color: Color {
        switch self {
        case .perfect: return Theme.good
        case .great: return Theme.accent
        case .good: return Theme.warn
        case .meh: return Color(red: 1.0, green: 0.58, blue: 0.30)
        case .miss: return Theme.bad
        }
    }
}

/// Draws one frame of the note lane. Pure drawing: all state comes from the session.
/// Per frame: gradient background (or the dimmed video), beat lines, a glowing hit zone, glowing notes, sparks and
/// bursts from `ParticleField`, a comet-tail cursor, rating pop-ups and combo flashes. Gradients are static.
@MainActor
enum LaneRenderer {
    /// Seconds of song visible to the right of the playhead.
    static let lookAhead = 4.5
    /// Playhead position as a fraction of the width.
    static let playheadFraction = 0.2
    static let topInset: CGFloat = 54
    static let bottomInset: CGFloat = 30

    private static let backgroundGradient = Gradient(colors: [Theme.laneTop, Theme.lane, Theme.lane])
    private static let hitZoneGradient = Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.22), Theme.accent.opacity(0)])
    private static let goodGlow = Gradient(colors: [Theme.good.opacity(0.7), Theme.good.opacity(0)])
    private static let voiceGlow = Gradient(colors: [Theme.accentSecondary.opacity(0.6), Theme.accentSecondary.opacity(0)])
    private static let confettiColors = [Theme.accent, Theme.accentSecondary, Theme.gold, Theme.good, Theme.violet]

    static func draw(
        _ context: inout GraphicsContext,
        size: CGSize,
        session: GameSession,
        songTime t: Double,
        host: Double,
        accidentals: Accidentals,
        showNoteNames: Bool,
        videoBehind: Bool = false
    ) {
        let width = size.width
        let height = size.height
        guard width > 0, height > topInset + bottomInset else { return }
        let song = session.song
        let range = session.pitchRange
        let span = max(1, range.upperBound - range.lowerBound)
        let playheadX = width * playheadFraction
        let pixelsPerSecond = (width - playheadX) / lookAhead
        let laneHeight = height - topInset - bottomInset
        let semitone = laneHeight / span

        func x(_ time: Double) -> CGFloat { playheadX + CGFloat(time - t) * pixelsPerSecond }
        func y(_ midi: Double) -> CGFloat {
            topInset + laneHeight * CGFloat(1 - (min(range.upperBound, max(range.lowerBound, midi)) - range.lowerBound) / span)
        }

        // Background: gradient, or a dark veil over the video so the notes stay readable.
        let full = Path(CGRect(origin: .zero, size: size))
        if videoBehind {
            context.fill(full, with: .color(Theme.lane.opacity(0.58)))
        } else {
            context.fill(full, with: .linearGradient(backgroundGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
        }

        // Semitone grid with C labels.
        let lowest = Int(range.lowerBound.rounded(.up))
        let highest = Int(range.upperBound.rounded(.down))
        if lowest <= highest {
            for note in lowest...highest {
                let isC = ((note % 12) + 12) % 12 == 0
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(Double(note))))
                line.addLine(to: CGPoint(x: width, y: y(Double(note))))
                context.stroke(line, with: .color(Theme.grid.opacity(isC ? 0.3 : 0.07)), lineWidth: isC ? 1 : 0.5)
                if isC {
                    let label = Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    context.draw(label, at: CGPoint(x: 6, y: y(Double(note)) - 1), anchor: .bottomLeading)
                }
            }
        }

        // Beat lines scrolling with the song (from the click grid), brighter as they reach the playhead.
        let leftSeconds = Double(playheadX / pixelsPerSecond)
        for beat in song.clickTimes(from: max(0, t - leftSeconds), to: t + lookAhead) {
            let bx = x(beat)
            let near = max(0, 1 - abs(beat - t) / 0.35)
            var line = Path()
            line.move(to: CGPoint(x: bx, y: topInset - 8))
            line.addLine(to: CGPoint(x: bx, y: height - bottomInset + 8))
            context.stroke(line, with: .color(Theme.violet.opacity(0.07 + 0.25 * near)), lineWidth: 1 + near)
        }

        // Hit zone: a soft column at the playhead that glows brighter with the multiplier.
        let multiplier = Double(max(1, session.multiplier))
        let zoneWidth: CGFloat = 70
        var zone = context
        zone.opacity = min(1, 0.55 + 0.15 * multiplier)
        zone.fill(
            Path(CGRect(x: playheadX - zoneWidth / 2, y: 0, width: zoneWidth, height: height)),
            with: .linearGradient(hitZoneGradient, startPoint: CGPoint(x: playheadX - zoneWidth / 2, y: 0), endPoint: CGPoint(x: playheadX + zoneWidth / 2, y: 0))
        )
        var playhead = Path()
        playhead.move(to: CGPoint(x: playheadX, y: topInset - 12))
        playhead.addLine(to: CGPoint(x: playheadX, y: height - bottomInset + 12))
        context.stroke(playhead, with: .color(Theme.accent.opacity(0.55)), lineWidth: 2)

        // Notes: soft glow underneath, solid bar, bright core on the note being sung right.
        let barHeight = max(8, min(22, semitone * 0.72))
        let visible = session.noteIndex.indices(overlapping: t - leftSeconds - 0.5, t + lookAhead + 0.5)
        let onPitch = session.onPitchNote.flatMap { abs($0.time - session.latestFrameSongTime) < 0.001 ? $0.index : nil }
        let pulse = 0.5 + 0.5 * sin(host * 10)
        for index in visible {
            let note = song.notes[index]
            let startX = x(note.start)
            let endX = x(note.end)
            let noteY = y(Double(note.pitch))
            let inset = min(barHeight / 2, max(0, (endX - startX) / 2))
            var path = Path()
            if note.slidesFromPrevious, index > 0 {
                let fromY = y(Double(song.notes[index - 1].pitch))
                let glideEnd = x(note.start + min(note.duration, note.slideDuration ?? note.duration))
                let mid = (startX + glideEnd) / 2
                path.move(to: CGPoint(x: startX, y: fromY))
                path.addCurve(
                    to: CGPoint(x: max(startX, glideEnd), y: noteY),
                    control1: CGPoint(x: mid, y: fromY),
                    control2: CGPoint(x: mid, y: noteY)
                )
                if endX - inset > glideEnd { path.addLine(to: CGPoint(x: endX - inset, y: noteY)) }
            } else {
                path.move(to: CGPoint(x: startX + inset, y: noteY))
                path.addLine(to: CGPoint(x: endX - inset, y: noteY))
            }

            let rating = session.ratings[index]
            let isPast = note.end < t
            let isActive = note.start <= t && note.end >= t
            let color: Color
            if note.isFreestyle {
                color = Theme.textSecondary.opacity(0.45)
            } else if let rating {
                color = rating.color.opacity(0.8)
            } else if isPast {
                color = Theme.textSecondary.opacity(0.35)
            } else if note.isGolden {
                color = Theme.gold
            } else {
                color = Theme.accent.opacity(0.95)
            }

            if note.isFreestyle {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
            } else {
                let glowColor = note.isGolden && rating == nil ? Theme.gold : (rating?.color ?? Theme.accent)
                if !isPast || rating != nil {
                    let glowWidth = barHeight + (isActive ? 14 + 6 * pulse : 9)
                    context.stroke(path, with: .color(glowColor.opacity(isActive ? 0.32 : 0.16)),
                                   style: StrokeStyle(lineWidth: glowWidth, lineCap: .round, lineJoin: .round))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: barHeight, lineCap: .round, lineJoin: .round))
                // Glossy highlight along the top of the bar.
                var shine = path
                shine = shine.offsetBy(dx: 0, dy: -barHeight * 0.18)
                context.stroke(shine, with: .color(.white.opacity(isPast && rating == nil ? 0.05 : 0.22)),
                               style: StrokeStyle(lineWidth: barHeight * 0.22, lineCap: .round, lineJoin: .round))
                if onPitch == index {
                    context.stroke(path, with: .color(.white.opacity(0.35 + 0.3 * pulse)),
                                   style: StrokeStyle(lineWidth: barHeight * 0.45, lineCap: .round, lineJoin: .round))
                }
            }

            let lyric = index < session.lyrics.primary.count ? session.lyrics.primary[index] : note.displayLyric
            if !lyric.isEmpty {
                let text = Text(lyric)
                    .font(.system(size: isActive ? 16 : 14, weight: isActive ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(isPast ? Theme.textSecondary.opacity(0.6) : (isActive ? Theme.gold : Theme.textPrimary))
                context.draw(text, at: CGPoint(x: startX, y: noteY + barHeight / 2 + 3), anchor: .topLeading)
            }
            // "Romaji + Japanese": the original script in small type under the romaji.
            if let secondary = session.lyrics.secondary, index < secondary.count, !secondary[index].isEmpty {
                let original = Text(secondary[index])
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(isPast ? 0.5 : 0.9))
                context.draw(original, at: CGPoint(x: startX, y: noteY + barHeight / 2 + 21), anchor: .topLeading)
            }
            if showNoteNames {
                let name = Text(NoteNaming.name(forMIDINote: note.pitch, accidentals: accidentals))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                context.draw(name, at: CGPoint(x: startX, y: noteY - barHeight / 2 - 2), anchor: .bottomLeading)
            }
        }

        // Particles (sparks, bursts, golden showers), anchored to the lane so they drift with the notes.
        let field = session.particles
        field.forEachLive(at: t) { particle, age, remaining in
            let offset = field.offset(of: particle, age: age)
            let px = x(particle.originTime) + CGFloat(offset.dx)
            let py = y(particle.originMidi) + CGFloat(offset.dy)
            let radius = CGFloat(particle.size * (0.4 + 0.6 * remaining))
            let tint: Color
            switch particle.kind {
            case .spark: tint = onPitch != nil ? Theme.good : Theme.accentSecondary
            case .burst: tint = particle.hue < 0.5 ? Theme.accent : .white
            case .golden: tint = particle.hue < 0.6 ? Theme.gold : .white
            case .confetti: tint = confettiColors[min(confettiColors.count - 1, Int(particle.hue * Double(confettiColors.count)))]
            }
            context.fill(Path(ellipseIn: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)),
                         with: .color(tint.opacity(remaining)))
        }

        // Rating pop-ups (with points), rising and fading above finished notes.
        for popup in session.popups {
            let age = t - popup.songTime
            guard age >= 0, age < 1.2, popup.noteIndex < song.notes.count else { continue }
            let note = song.notes[popup.noteIndex]
            let fade = max(0, 1 - age / 1.2)
            let pop = age < 0.1 ? 0.6 + 4 * age : 1.0
            let point = CGPoint(x: x(note.end), y: y(Double(note.pitch)) - barHeight - 6 - CGFloat(age) * 30)
            let label = Text(popup.rating.displayName)
                .font(.system(size: 18 * pop, weight: .heavy, design: .rounded))
                .foregroundStyle(popup.rating.color.opacity(fade))
            context.draw(label, at: point, anchor: .bottom)
            if popup.points > 0 {
                let points = Text("+\(popup.points)")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary.opacity(0.8 * fade))
                context.draw(points, at: CGPoint(x: point.x, y: point.y + 2), anchor: .top)
            }
        }

        // Sung pitch: a tapering comet tail behind the playhead and a glowing, pulsing head.
        let tint = onPitch != nil ? Theme.good : Theme.accentSecondary
        if let newest = session.trail.last {
            var previous: GameSession.TrailPoint?
            for point in session.trail {
                defer { previous = point }
                guard let previous, point.time - previous.time < 0.045 else { continue }
                let age = newest.time - point.time
                guard age < 0.5 else { continue }
                let life = 1 - age / 0.5
                var segment = Path()
                segment.move(to: CGPoint(x: playheadX - CGFloat(newest.time - previous.time) * pixelsPerSecond, y: y(previous.midi)))
                segment.addLine(to: CGPoint(x: playheadX - CGFloat(age) * pixelsPerSecond, y: y(point.midi)))
                context.stroke(segment, with: .color(tint.opacity(0.22 * life)), style: StrokeStyle(lineWidth: 12 * life + 2, lineCap: .round))
                context.stroke(segment, with: .color(tint.opacity(0.9 * life)), style: StrokeStyle(lineWidth: 5 * life + 1, lineCap: .round))
            }
        }
        if let voiced = session.latestVoiced, session.latestFrameSongTime - voiced.time < 0.03 {
            let center = CGPoint(x: playheadX, y: y(voiced.midi))
            let glowRadius: CGFloat = onPitch != nil ? 28 + 6 * pulse : 22
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(onPitch != nil ? goodGlow : voiceGlow, center: center, startRadius: 2, endRadius: glowRadius)
            )
            if onPitch != nil {
                let ring = 11 + 5 * pulse
                context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                               with: .color(Theme.good.opacity(0.8)), lineWidth: 2)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(tint))
        }

        // Combo milestones and multiplier ups: a big word that pops and fades.
        if let flash = session.comboFlash, t - flash.time >= 0, t - flash.time < 1.3 {
            drawFlash(&context, text: "\(flash.combo) COMBO!", color: Theme.gold, age: t - flash.time, at: CGPoint(x: width * 0.55, y: topInset + laneHeight * 0.28))
        } else if let flash = session.multiplierFlash, t - flash.time >= 0, t - flash.time < 1.0 {
            drawFlash(&context, text: "×\(flash.value)", color: Theme.accent, age: t - flash.time, at: CGPoint(x: width * 0.55, y: topInset + laneHeight * 0.28))
        }

        // Countdown (start and resume), popping on each number.
        if let count = session.countdown(atHost: host) {
            let fraction = host.truncatingRemainder(dividingBy: 1)
            let scale = 1 + 0.25 * max(0, 1 - fraction * 4)
            let text = Text("\(count)")
                .font(.system(size: 96 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
            context.draw(text, at: CGPoint(x: width / 2, y: height / 2), anchor: .center)
        }
    }

    private static func drawFlash(_ context: inout GraphicsContext, text: String, color: Color, age: Double, at point: CGPoint) {
        let grow = age < 0.15 ? 0.6 + 0.6 * (age / 0.15) : max(1, 1.2 - (age - 0.15) * 0.4)
        let fade = age < 0.8 ? 1 : max(0, 1 - (age - 0.8) / 0.5)
        let shadow = Text(text)
            .font(.system(size: 44 * grow, weight: .black, design: .rounded))
            .foregroundStyle(color.opacity(0.35 * fade))
        context.draw(shadow, at: CGPoint(x: point.x + 2, y: point.y + 3), anchor: .center)
        let label = Text(text)
            .font(.system(size: 44 * grow, weight: .black, design: .rounded))
            .foregroundStyle(color.opacity(fade))
        context.draw(label, at: point, anchor: .center)
    }
}
#endif
