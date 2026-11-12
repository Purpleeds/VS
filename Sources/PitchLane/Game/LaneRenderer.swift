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
@MainActor
enum LaneRenderer {
    /// Seconds of song visible to the right of the playhead.
    static let lookAhead = 4.5
    /// Playhead position as a fraction of the width.
    static let playheadFraction = 0.2
    static let topInset: CGFloat = 54
    static let bottomInset: CGFloat = 30

    static func draw(
        _ context: inout GraphicsContext,
        size: CGSize,
        session: GameSession,
        songTime t: Double,
        host: Double,
        accidentals: Accidentals,
        showNoteNames: Bool
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

        // Background and semitone grid.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.lane))
        let lowest = Int(range.lowerBound.rounded(.up))
        let highest = Int(range.upperBound.rounded(.down))
        if lowest <= highest {
            for note in lowest...highest {
                let isC = ((note % 12) + 12) % 12 == 0
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(Double(note))))
                line.addLine(to: CGPoint(x: width, y: y(Double(note))))
                context.stroke(line, with: .color(Theme.grid.opacity(isC ? 0.32 : 0.09)), lineWidth: isC ? 1 : 0.5)
                if isC {
                    let label = Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    context.draw(label, at: CGPoint(x: 6, y: y(Double(note)) - 1), anchor: .bottomLeading)
                }
            }
        }

        // Playhead.
        var playhead = Path()
        playhead.move(to: CGPoint(x: playheadX, y: topInset - 10))
        playhead.addLine(to: CGPoint(x: playheadX, y: height - bottomInset + 10))
        context.stroke(playhead, with: .color(Theme.accent.opacity(0.35)), lineWidth: 2)

        // Notes.
        let barHeight = max(8, min(22, semitone * 0.72))
        let visible = session.noteIndex.indices(overlapping: t - Double(playheadX / pixelsPerSecond) - 0.5, t + lookAhead + 0.5)
        let onPitch = session.onPitchNote.flatMap { abs($0.time - session.latestFrameSongTime) < 0.001 ? $0.index : nil }
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
            let color: Color
            if note.isFreestyle {
                color = Theme.textSecondary.opacity(0.45)
            } else if let rating {
                color = rating.color.opacity(0.75)
            } else if isPast {
                color = Theme.textSecondary.opacity(0.4)
            } else if note.isGolden {
                color = Theme.gold
            } else {
                color = Theme.accent.opacity(0.9)
            }

            if note.isGolden, rating == nil {
                context.stroke(path, with: .color(Theme.gold.opacity(0.25)), style: StrokeStyle(lineWidth: barHeight + 10, lineCap: .round, lineJoin: .round))
            }
            if note.isFreestyle {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: barHeight, lineCap: .round, lineJoin: .round))
                if onPitch == index {
                    context.stroke(path, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: barHeight * 0.45, lineCap: .round, lineJoin: .round))
                }
            }

            let lyric = note.displayLyric
            if !lyric.isEmpty {
                let text = Text(lyric)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isPast ? Theme.textSecondary.opacity(0.6) : Theme.textPrimary)
                context.draw(text, at: CGPoint(x: startX, y: noteY + barHeight / 2 + 3), anchor: .topLeading)
            }
            if showNoteNames {
                let name = Text(NoteNaming.name(forMIDINote: note.pitch, accidentals: accidentals))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                context.draw(name, at: CGPoint(x: startX, y: noteY - barHeight / 2 - 2), anchor: .bottomLeading)
            }
        }

        // Rating pop-ups, rising and fading above finished notes.
        for popup in session.popups {
            let age = t - popup.songTime
            guard age >= 0, age < 1.2, popup.noteIndex < song.notes.count else { continue }
            let note = song.notes[popup.noteIndex]
            let fade = max(0, 1 - age / 1.2)
            let label = Text(popup.rating.displayName)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(popup.rating.color.opacity(fade))
            let point = CGPoint(x: x(note.end), y: y(Double(note.pitch)) - barHeight - 6 - CGFloat(age) * 28)
            context.draw(label, at: point, anchor: .bottom)
        }

        // Sung pitch: fading trail behind the playhead, glowing dot on it.
        if let newest = session.trail.last {
            var previous: GameSession.TrailPoint?
            for point in session.trail {
                defer { previous = point }
                guard let previous, point.time - previous.time < 0.045 else { continue }
                let age = newest.time - point.time
                guard age < 0.45 else { continue }
                var segment = Path()
                segment.move(to: CGPoint(x: playheadX - CGFloat(newest.time - previous.time) * pixelsPerSecond, y: y(previous.midi)))
                segment.addLine(to: CGPoint(x: playheadX - CGFloat(age) * pixelsPerSecond, y: y(point.midi)))
                context.stroke(segment, with: .color(Theme.accentSecondary.opacity(0.85 * (1 - age / 0.45))), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
        if let voiced = session.latestVoiced, session.latestFrameSongTime - voiced.time < 0.03 {
            let center = CGPoint(x: playheadX, y: y(voiced.midi))
            let tint = onPitch != nil ? Theme.good : Theme.accentSecondary
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)),
                with: .radialGradient(Gradient(colors: [tint.opacity(0.55), tint.opacity(0)]), center: center, startRadius: 2, endRadius: 22)
            )
            context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(tint))
        }

        // Countdown (start and resume).
        if let count = session.clock.countdown(at: host), session.phase == .running {
            let text = Text("\(count)")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
            context.draw(text, at: CGPoint(x: width / 2, y: height / 2), anchor: .center)
        }
    }
}
#endif
