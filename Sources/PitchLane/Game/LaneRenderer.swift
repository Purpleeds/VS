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
/// Per frame, back to front: stage background (gradient with two slow glows, or the dimmed video), piano-roll rows
/// (darker black-key semitones), beat lines, the hit zone with a semitone ruler, shaded glowing notes (golden ones
/// shimmer), veils that dim the past and fade notes in on the right, octave labels, the "sing here" marker, sparks,
/// rating pop-ups, the comet-tail cursor, combo flashes, the song progress bar, the karaoke lyric strip, and the
/// title card and countdown ring. Gradients are static.
@MainActor
enum LaneRenderer {
    /// Seconds of song visible to the right of the playhead.
    static let lookAhead = 4.5
    /// Playhead position as a fraction of the width.
    static let playheadFraction = 0.2
    static let topInset: CGFloat = 58
    static let bottomInset: CGFloat = 26
    /// Height of the karaoke strip (songs with lyrics); taller with the original script under the romaji.
    static let stripHeight: CGFloat = 58
    static let stripHeightTwoLines: CGFloat = 70

    private static let backgroundGradient = Gradient(colors: [Theme.laneTop, Theme.lane, Theme.lane])
    private static let stageGlowViolet = Gradient(colors: [Theme.violet.opacity(0.20), Theme.violet.opacity(0)])
    private static let stageGlowTeal = Gradient(colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0)])
    private static let hitZoneGradient = Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.24), Theme.accent.opacity(0)])
    private static let pastVeil = Gradient(colors: [Theme.lane.opacity(0.62), Theme.lane.opacity(0.18)])
    private static let futureFade = Gradient(colors: [Theme.lane.opacity(0), Theme.lane.opacity(0.9)])
    private static let stripGradient = Gradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.78), Theme.background.opacity(0.9)])
    private static let progressGradient = Gradient(colors: [Theme.accent, Theme.violet, Theme.accentSecondary])
    private static let goodGlow = Gradient(colors: [Theme.good.opacity(0.7), Theme.good.opacity(0)])
    private static let voiceGlow = Gradient(colors: [Theme.accentSecondary.opacity(0.6), Theme.accentSecondary.opacity(0)])
    private static let confettiColors = [Theme.accent, Theme.accentSecondary, Theme.gold, Theme.good, Theme.violet]
    /// Bit n set = pitch class n is a black key (C♯, D♯, F♯, G♯, A♯).
    private static let blackKeys = 0b0101_0100_1010

    /// Bar shading, top to bottom: highlight, colour, shadow.
    private static func shade(_ color: Color) -> Gradient {
        Gradient(colors: [color.mix(with: .white, by: 0.45), color, color.mix(with: .black, by: 0.3)])
    }
    private static let accentShade = shade(Theme.accent)
    private static let goldShade = shade(Theme.gold)
    private static let pastShade = shade(Theme.textSecondary.opacity(0.35))
    private static let freestyleColor = Theme.textSecondary.opacity(0.45)
    private static let ratingShades: [NoteRating: Gradient] = Dictionary(uniqueKeysWithValues: NoteRating.allCases.map { ($0, shade($0.color.opacity(0.85))) })

    static func draw(
        _ context: inout GraphicsContext,
        size: CGSize,
        session: GameSession,
        songTime t: Double,
        host: Double,
        accidentals: Accidentals,
        showNoteNames: Bool,
        videoBehind: Bool = false,
        reduceMotion: Bool = false
    ) {
        let width = size.width
        let height = size.height
        let strip: CGFloat = session.karaoke.isEmpty ? 0 : (session.lyrics.secondary == nil ? stripHeight : stripHeightTwoLines)
        let bottom = bottomInset + strip
        guard width > 0, height > topInset + bottom + 40 else { return }
        let song = session.song
        let range = session.pitchRange
        let span = max(1, range.upperBound - range.lowerBound)
        let playheadX = width * playheadFraction
        let pixelsPerSecond = (width - playheadX) / lookAhead
        let laneHeight = height - topInset - bottom
        let semitone = laneHeight / span
        let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(host * 10)

        func x(_ time: Double) -> CGFloat { playheadX + CGFloat(time - t) * pixelsPerSecond }
        func y(_ midi: Double) -> CGFloat {
            topInset + laneHeight * CGFloat(1 - (min(range.upperBound, max(range.lowerBound, midi)) - range.lowerBound) / span)
        }

        // Stage: gradient with two slow-drifting glows, or a dark veil over the video so the notes stay readable.
        let full = Path(CGRect(origin: .zero, size: size))
        if videoBehind {
            context.fill(full, with: .color(Theme.lane.opacity(0.58)))
        } else {
            context.fill(full, with: .linearGradient(backgroundGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
            let drift = reduceMotion ? 0 : host * 0.07
            let violetCenter = CGPoint(x: width * (0.68 + 0.08 * sin(drift)), y: height * (0.3 + 0.06 * cos(drift * 0.8)))
            let violetRadius = max(width, height) * 0.5
            context.fill(Path(ellipseIn: CGRect(x: violetCenter.x - violetRadius, y: violetCenter.y - violetRadius, width: violetRadius * 2, height: violetRadius * 2)),
                         with: .radialGradient(stageGlowViolet, center: violetCenter, startRadius: 0, endRadius: violetRadius))
            let tealCenter = CGPoint(x: width * (0.3 + 0.07 * cos(drift * 1.2)), y: height * 0.85)
            let tealRadius = max(width, height) * 0.42
            context.fill(Path(ellipseIn: CGRect(x: tealCenter.x - tealRadius, y: tealCenter.y - tealRadius, width: tealRadius * 2, height: tealRadius * 2)),
                         with: .radialGradient(stageGlowTeal, center: tealCenter, startRadius: 0, endRadius: tealRadius))
        }

        // Piano-roll rows: black-key semitones a little darker, so pitch is easy to read across the lane.
        let lowest = Int(range.lowerBound.rounded(.up))
        let highest = Int(range.upperBound.rounded(.down))
        if lowest <= highest {
            for note in lowest...highest {
                let pitchClass = ((note % 12) + 12) % 12
                if (blackKeys >> pitchClass) & 1 == 1 {
                    let top = y(Double(note) + 0.5), bottomY = y(Double(note) - 0.5)
                    context.fill(Path(CGRect(x: 0, y: top, width: width, height: max(0, bottomY - top))), with: .color(Theme.background.opacity(0.22)))
                }
                let isC = pitchClass == 0
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(Double(note))))
                line.addLine(to: CGPoint(x: width, y: y(Double(note))))
                context.stroke(line, with: .color(Theme.grid.opacity(isC ? 0.28 : 0.06)), lineWidth: isC ? 1 : 0.5)
            }
        }

        // Beat lines scrolling with the song (from the click grid), brighter as they reach the playhead.
        let leftSeconds = Double(playheadX / pixelsPerSecond)
        for beat in song.clickTimes(from: max(0, t - leftSeconds), to: t + lookAhead) {
            let bx = x(beat)
            let near = max(0, 1 - abs(beat - t) / 0.35)
            var line = Path()
            line.move(to: CGPoint(x: bx, y: topInset - 8))
            line.addLine(to: CGPoint(x: bx, y: height - bottom + 8))
            context.stroke(line, with: .color(Theme.violet.opacity(0.07 + 0.25 * near)), lineWidth: 1 + near)
        }

        // Hit zone: a soft column at the playhead that glows brighter with the multiplier, with a semitone ruler.
        let multiplier = Double(max(1, session.multiplier))
        let zoneWidth: CGFloat = 76
        var zone = context
        zone.opacity = min(1, 0.55 + 0.15 * multiplier)
        zone.fill(
            Path(CGRect(x: playheadX - zoneWidth / 2, y: 0, width: zoneWidth, height: height - strip)),
            with: .linearGradient(hitZoneGradient, startPoint: CGPoint(x: playheadX - zoneWidth / 2, y: 0), endPoint: CGPoint(x: playheadX + zoneWidth / 2, y: 0))
        )
        var playhead = Path()
        playhead.move(to: CGPoint(x: playheadX, y: topInset - 12))
        playhead.addLine(to: CGPoint(x: playheadX, y: height - bottom + 12))
        context.stroke(playhead, with: .color(Theme.accent.opacity(0.6)), lineWidth: 2)
        if lowest <= highest {
            var ticks = Path()
            for note in lowest...highest {
                let isC = ((note % 12) + 12) % 12 == 0
                let length: CGFloat = isC ? 9 : 4
                ticks.move(to: CGPoint(x: playheadX - length, y: y(Double(note))))
                ticks.addLine(to: CGPoint(x: playheadX + length, y: y(Double(note))))
            }
            context.stroke(ticks, with: .color(Theme.accent.opacity(0.45)), lineWidth: 1)
        }

        // Notes: soft glow, dark outline, shaded bar, gloss, bright core on the note being sung right.
        let barHeight = max(8, min(22, semitone * 0.72))
        let visible = session.noteIndex.indices(overlapping: t - leftSeconds - 0.5, t + lookAhead + 0.5)
        let onPitch = session.onPitchNote.flatMap { abs($0.time - session.latestFrameSongTime) < 0.001 ? $0.index : nil }
        var upcoming: SongNote?
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
            if upcoming == nil, !note.isFreestyle, note.end >= t, note.start - t <= 1.5 { upcoming = note }

            if note.isFreestyle {
                context.stroke(path, with: .color(freestyleColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
            } else {
                let gradient: Gradient
                if let rating {
                    gradient = ratingShades[rating] ?? accentShade
                } else if isPast {
                    gradient = pastShade
                } else if note.isGolden {
                    gradient = goldShade
                } else {
                    gradient = accentShade
                }
                let bar = StrokeStyle(lineWidth: barHeight, lineCap: .round, lineJoin: .round)
                let glowColor = note.isGolden && rating == nil ? Theme.gold : (rating?.color ?? Theme.accent)
                if !isPast || rating != nil {
                    let glowWidth = barHeight + (isActive ? 14 + 6 * pulse : 9)
                    context.stroke(path, with: .color(glowColor.opacity(isActive ? 0.32 : 0.16)),
                                   style: StrokeStyle(lineWidth: glowWidth, lineCap: .round, lineJoin: .round))
                }
                context.stroke(path, with: .color(Theme.background.opacity(isPast && rating == nil ? 0.3 : 0.6)),
                               style: StrokeStyle(lineWidth: barHeight + 3, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .linearGradient(gradient, startPoint: CGPoint(x: startX, y: noteY - barHeight / 2),
                                                           endPoint: CGPoint(x: startX, y: noteY + barHeight / 2)), style: bar)
                // Gloss along the top of the bar.
                let shine = path.offsetBy(dx: 0, dy: -barHeight * 0.2)
                context.stroke(shine, with: .color(.white.opacity(isPast && rating == nil ? 0.04 : 0.18)),
                               style: StrokeStyle(lineWidth: barHeight * 0.18, lineCap: .round, lineJoin: .round))
                // Golden notes still to sing: a glint sweeping along the bar.
                if note.isGolden, rating == nil, !isPast, !reduceMotion, endX - startX > barHeight {
                    let phase = (host * 0.9 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1)
                    let gx = startX + inset + (endX - startX - 2 * inset) * CGFloat(phase)
                    var glint = Path()
                    glint.move(to: CGPoint(x: max(startX + inset, gx - 9), y: noteY - barHeight * 0.12))
                    glint.addLine(to: CGPoint(x: min(endX - inset, gx + 9), y: noteY - barHeight * 0.12))
                    context.stroke(glint, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: barHeight * 0.32, lineCap: .round))
                }
                if onPitch == index {
                    context.stroke(path, with: .color(.white.opacity(0.35 + 0.3 * pulse)),
                                   style: StrokeStyle(lineWidth: barHeight * 0.45, lineCap: .round, lineJoin: .round))
                }
            }

            // Words are in the karaoke strip under the lane, not on the notes.
            if showNoteNames {
                let name = Text(NoteNaming.name(forMIDINote: note.pitch, accidentals: accidentals))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                context.draw(name, at: CGPoint(x: startX, y: noteY - barHeight / 2 - 2), anchor: .bottomLeading)
            }
        }

        // Veils: the past dims behind the playhead; new notes fade in from the right edge.
        context.fill(Path(CGRect(x: 0, y: 0, width: playheadX - 3, height: height - strip)),
                     with: .linearGradient(pastVeil, startPoint: .zero, endPoint: CGPoint(x: playheadX, y: 0)))
        let fadeWidth: CGFloat = 70
        context.fill(Path(CGRect(x: width - fadeWidth, y: 0, width: fadeWidth, height: height - strip)),
                     with: .linearGradient(futureFade, startPoint: CGPoint(x: width - fadeWidth, y: 0), endPoint: CGPoint(x: width, y: 0)))

        // Octave labels (on top of the veil so they stay readable).
        if lowest <= highest {
            for note in lowest...highest where ((note % 12) + 12) % 12 == 0 {
                let label = Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                context.draw(label, at: CGPoint(x: 6, y: y(Double(note)) - 1), anchor: .bottomLeading)
            }
        }

        // "Sing here": a marker on the playhead at the pitch of the note being sung or coming up next.
        if let next = upcoming {
            let ahead = max(0, next.start - t)
            let strength = next.start <= t ? 1 : max(0, 1 - ahead / 1.5)
            let my = y(Double(next.pitch))
            let color = next.isGolden ? Theme.gold : Theme.accent
            var marker = Path()
            marker.move(to: CGPoint(x: playheadX - 18, y: my - 7))
            marker.addLine(to: CGPoint(x: playheadX - 7, y: my))
            marker.addLine(to: CGPoint(x: playheadX - 18, y: my + 7))
            marker.closeSubpath()
            context.fill(marker, with: .color(color.opacity(0.25 + 0.7 * strength)))
            var mirror = Path()
            mirror.move(to: CGPoint(x: playheadX + 18, y: my - 7))
            mirror.addLine(to: CGPoint(x: playheadX + 7, y: my))
            mirror.addLine(to: CGPoint(x: playheadX + 18, y: my + 7))
            mirror.closeSubpath()
            context.fill(mirror, with: .color(color.opacity(0.15 + 0.5 * strength)))
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

        // Rating pop-ups (with points), rising and fading above finished notes, with a shadow for contrast.
        for popup in session.popups {
            let age = t - popup.songTime
            guard age >= 0, age < 1.2, popup.noteIndex < song.notes.count else { continue }
            let note = song.notes[popup.noteIndex]
            let fade = max(0, 1 - age / 1.2)
            let pop = age < 0.1 ? 0.6 + 4 * age : 1.0
            let point = CGPoint(x: x(note.end), y: y(Double(note.pitch)) - barHeight - 6 - CGFloat(age) * 30)
            let font = Font.system(size: 18 * pop, weight: .heavy, design: .rounded)
            context.draw(Text(popup.rating.displayName).font(font).foregroundStyle(Theme.background.opacity(0.7 * fade)),
                         at: CGPoint(x: point.x + 1.5, y: point.y + 1.5), anchor: .bottom)
            context.draw(Text(popup.rating.displayName).font(font).foregroundStyle(popup.rating.color.opacity(fade)), at: point, anchor: .bottom)
            if popup.points > 0 {
                let points = Text("+\(popup.points)")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary.opacity(0.85 * fade))
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
            let glowRadius: CGFloat = onPitch != nil ? 30 + 6 * pulse : 22
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(onPitch != nil ? goodGlow : voiceGlow, center: center, startRadius: 2, endRadius: glowRadius)
            )
            if onPitch != nil {
                let ring = 12 + 5 * pulse
                context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                               with: .color(Theme.good.opacity(0.85)), lineWidth: 2)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(Theme.background.opacity(0.6)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(tint))
        }

        // Combo milestones and multiplier ups: a big word that pops and fades.
        let flashPoint = CGPoint(x: width * 0.55, y: topInset + laneHeight * 0.28)
        if let flash = session.comboFlash, t - flash.time >= 0, t - flash.time < 1.3 {
            drawFlash(&context, text: "\(flash.combo) COMBO!", color: Theme.gold, age: t - flash.time, at: flashPoint)
        } else if let flash = session.multiplierFlash, t - flash.time >= 0, t - flash.time < 1.0 {
            drawFlash(&context, text: "×\(flash.value)", color: Theme.accent, age: t - flash.time, at: flashPoint)
        }

        // Song progress along the very top.
        if session.songEnd > 0 {
            let fraction = CGFloat(min(1, max(0, t / session.songEnd)))
            context.fill(Path(CGRect(x: 0, y: 0, width: width, height: 3)), with: .color(Theme.surface.opacity(0.8)))
            context.fill(Path(CGRect(x: 0, y: 0, width: width * fraction, height: 3)),
                         with: .linearGradient(progressGradient, startPoint: .zero, endPoint: CGPoint(x: width, y: 0)))
        }

        if strip > 0 {
            drawKaraoke(&context, session: session, time: t, rect: CGRect(x: 0, y: height - strip, width: width, height: strip))
        }

        // Before the song starts: the title card. Start and resume: the countdown with a draining ring.
        if t < -0.4, session.countdown(atHost: host) != nil {
            drawTitleCard(&context, session: session, time: t, center: CGPoint(x: width / 2, y: height * 0.27))
        }
        if let count = session.countdown(atHost: host) {
            let fraction = host.truncatingRemainder(dividingBy: 1)
            let scale = 1 + 0.25 * max(0, 1 - fraction * 4)
            let center = CGPoint(x: width / 2, y: height * 0.55)
            let ring: CGFloat = 58
            context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(Theme.surface.opacity(0.8)), lineWidth: 6)
            var arc = Path()
            arc.addArc(center: center, radius: ring, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * (1 - fraction)), clockwise: false)
            context.stroke(arc, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            let text = Text("\(count)")
                .font(.system(size: 76 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
            context.draw(text, at: center, anchor: .center)
        }
    }

    /// The karaoke strip: the line being sung, each word lighting up as it is sung (a gold wipe through the current
    /// one), and the next line (or the original script) underneath.
    private static func drawKaraoke(_ context: inout GraphicsContext, session: GameSession, time t: Double, rect: CGRect) {
        context.fill(Path(rect), with: .linearGradient(stripGradient, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        var hairline = Path()
        hairline.move(to: CGPoint(x: rect.minX + 40, y: rect.minY + 1))
        hairline.addLine(to: CGPoint(x: rect.maxX - 40, y: rect.minY + 1))
        context.stroke(hairline, with: .color(Theme.violet.opacity(0.25)), lineWidth: 1)
        let lines = session.karaoke
        guard let index = KaraokeLines.current(lines, at: t) else { return }
        let line = lines[index]
        let started = t >= line.start - 0.05
        let maxWidth = rect.width - 40
        var size: CGFloat = 21
        var resolved: [(text: GraphicsContext.ResolvedText, wipe: GraphicsContext.ResolvedText?, width: CGFloat, height: CGFloat)] = []
        for _ in 0..<2 {
            resolved.removeAll(keepingCapacity: true)
            let font = Font.system(size: size, weight: .bold, design: .rounded)
            for piece in line.pieces {
                let color: Color
                var wipe: GraphicsContext.ResolvedText?
                if !started {
                    color = Theme.textPrimary.opacity(0.65)
                } else if piece.end <= t {
                    color = Theme.accent
                } else if piece.start <= t {
                    color = Theme.textPrimary
                    wipe = context.resolve(Text(piece.text).font(font).foregroundStyle(Theme.gold))
                } else {
                    color = Theme.textPrimary.opacity(0.9)
                }
                let text = context.resolve(Text(piece.text).font(font).foregroundStyle(color))
                let measured = text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                resolved.append((text, wipe, measured.width, measured.height))
            }
            let total = resolved.reduce(0) { $0 + $1.width }
            if total <= maxWidth || size < 16 { break }
            size = max(14, size * maxWidth / total)
        }
        let total = resolved.reduce(0) { $0 + $1.width }
        var px = rect.minX + max(20, (rect.width - total) / 2)
        let py = rect.minY + 9
        for (offset, piece) in line.pieces.enumerated() where offset < resolved.count {
            let item = resolved[offset]
            context.draw(item.text, at: CGPoint(x: px, y: py), anchor: .topLeading)
            if let wipe = item.wipe {
                var clipped = context
                clipped.clip(to: Path(CGRect(x: px, y: py - 4, width: item.width * CGFloat(KaraokeLines.progress(of: piece, at: t)), height: item.height + 8)))
                clipped.draw(wipe, at: CGPoint(x: px, y: py), anchor: .topLeading)
            }
            px += item.width
        }
        // Underneath: the original script of this line (romaji + original mode), else the next line.
        let below: String
        if let secondary = session.lyrics.secondary {
            below = line.pieces.compactMap { $0.noteIndex < secondary.count ? secondary[$0.noteIndex] : nil }.joined()
        } else if index + 1 < lines.count, lines[index + 1].start - t < 8 {
            below = lines[index + 1].text
        } else {
            below = ""
        }
        if !below.isEmpty {
            let next = Text(below)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
            context.draw(next, at: CGPoint(x: rect.midX, y: py + 30), anchor: .top)
        }
    }

    /// Song title, artist and difficulty, fading out as the countdown ends.
    private static func drawTitleCard(_ context: inout GraphicsContext, session: GameSession, time t: Double, center: CGPoint) {
        let fade = min(1, max(0, (-t - 0.4) / 0.6))
        let song = session.song
        let title = Text(song.title)
            .font(.system(size: 30, weight: .black, design: .rounded))
        context.draw(title.foregroundStyle(Theme.violet.opacity(0.6 * fade)), at: CGPoint(x: center.x, y: center.y + 2), anchor: .bottom)
        context.draw(title.foregroundStyle(Theme.textPrimary.opacity(fade)), at: center, anchor: .bottom)
        var detail = [session.options.difficulty.displayName.uppercased()]
        if !song.artist.isEmpty { detail.insert(song.artist, at: 0) }
        if session.options.practice.isPractice { detail.append("PRACTICE") }
        let subtitle = Text(detail.joined(separator: "  ·  "))
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary.opacity(fade))
        context.draw(subtitle, at: CGPoint(x: center.x, y: center.y + 6), anchor: .top)
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
