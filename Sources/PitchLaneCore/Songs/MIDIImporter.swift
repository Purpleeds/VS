import Foundation

/// Standard MIDI File (type 0 and 1) reader.
///
/// Reads every track (running status, sysex, meta events), builds one tempo map from all tempo events,
/// and lists tracks with note counts so the user can pick the melody. `song(track:)` turns one track into a
/// monophonic `Song`: wherever notes overlap (chords included) the highest sounding note wins, and a lower
/// note resumes when it ends. Lyric meta events on that track become syllables.
/// Malformed files throw `SongImportError` with the byte offset; nothing here traps on bad input.
public struct MIDIFile: Sendable {
    public struct Track: Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String?
        public var noteCount: Int
        /// 1-based MIDI channels used by notes.
        public var channels: [Int]
        public var lowestPitch: Int?
        public var highestPitch: Int?
        public var lyricCount: Int
        /// Every note is on channel 10.
        public var isDrums: Bool

        public var displayName: String {
            if let name, !name.isEmpty { return name }
            return "Track \(id + 1)"
        }
    }

    public let format: Int
    public let tracks: [Track]
    /// Sequence / first track name, if any.
    public let title: String?
    public let warnings: [String]

    private let tempoMap: TempoMap
    private let notesByTrack: [[RawNote]]
    private let lyricsByTrack: [[Lyric]]
    private let ticksPerQuarter: Int?

    /// Shortest note kept after chord collapsing.
    public static let minimumNoteDuration = 0.03

    /// Track most likely to be the melody: named like one, else carrying lyrics, else the busiest non-drum track.
    public var suggestedMelodyTrack: Int? {
        let candidates = tracks.filter { $0.noteCount > 0 && !$0.isDrums }
        let keywords = ["melody", "vocal", "voice", "lead", "sing", "lyric"]
        if let named = candidates.first(where: { track in
            let name = (track.name ?? "").lowercased()
            return keywords.contains { name.contains($0) }
        }) {
            return named.id
        }
        if let withLyrics = candidates.filter({ $0.lyricCount > 0 }).max(by: { $0.lyricCount < $1.lyricCount }) {
            return withLyrics.id
        }
        return candidates.max(by: { $0.noteCount < $1.noteCount })?.id
    }

    // MARK: Song conversion

    public func song(track index: Int, id: String = UUID().uuidString, title: String? = nil) throws -> Song {
        guard tracks.indices.contains(index) else {
            throw SongImportError("track \(index + 1) doesn't exist (file has \(tracks.count))")
        }
        let raw = notesByTrack[index]
        guard !raw.isEmpty else {
            throw SongImportError("\(tracks[index].displayName) has no notes; pick another track")
        }
        let segments = Self.monophonic(raw)
        let lyrics = lyricsByTrack[index]
        let tolerance = max(1, (ticksPerQuarter ?? 480) / 8)

        var notes: [SongNote] = []
        var lineBreaks: [Double] = []
        var lyricIndex = 0
        for segment in segments {
            let start = tempoMap.seconds(at: segment.start)
            let end = tempoMap.seconds(at: segment.end)
            guard end - start >= Self.minimumNoteDuration else { continue }
            var syllable = ""
            if segment.isNoteStart {
                while lyricIndex < lyrics.count, lyrics[lyricIndex].tick < segment.noteStart - tolerance {
                    lyricIndex += 1
                }
                if lyricIndex < lyrics.count, lyrics[lyricIndex].tick <= segment.noteStart + tolerance {
                    syllable = lyrics[lyricIndex].text
                    if lyrics[lyricIndex].startsLine { lineBreaks.append(start) }
                    lyricIndex += 1
                }
            }
            notes.append(SongNote(start: start, duration: end - start, pitch: segment.pitch, lyric: syllable))
        }
        guard !notes.isEmpty else {
            throw SongImportError("\(tracks[index].displayName) has no notes long enough to sing")
        }
        guard notes.count <= SongLimits.maximumNotes else {
            throw SongImportError("\(tracks[index].displayName) has \(notes.count) notes; the limit is \(SongLimits.maximumNotes)")
        }
        guard let last = notes.last, SongLimits.isSensible(start: last.start, duration: last.duration) else {
            throw SongImportError("\(tracks[index].displayName) is longer than a song can be")
        }
        let songTitle = SongLimits.clip(title ?? self.title ?? tracks[index].displayName)
        return Song(
            id: id,
            title: songTitle,
            artist: "",
            source: .midi,
            notes: notes,
            lineBreaks: lineBreaks,
            tempo: tempoMap.segments
        )
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> MIDIFile {
        var reader = ByteReader([UInt8](data))
        guard reader.remaining >= 14, try reader.fourCC() == "MThd" else {
            throw SongImportError(byteOffset: 0, "not a MIDI file (missing MThd header)")
        }
        let headerLength = Int(try reader.u32())
        guard headerLength >= 6 else {
            throw SongImportError(byteOffset: 4, "MIDI header is too short (\(headerLength) bytes)")
        }
        let format = Int(try reader.u16())
        let declaredTracks = Int(try reader.u16())
        let division = try reader.u16()
        try reader.skip(headerLength - 6)
        switch format {
        case 0, 1: break
        case 2: throw SongImportError(byteOffset: 8, "MIDI type 2 files (separate songs per track) aren't supported")
        default: throw SongImportError(byteOffset: 8, "unknown MIDI format \(format)")
        }

        var ticksPerQuarter: Int?
        var smpteSecondsPerTick: Double?
        if division & 0x8000 != 0 {
            let framesRaw = -Int(Int8(bitPattern: UInt8(division >> 8)))
            let ticksPerFrame = Int(division & 0xFF)
            let fps = framesRaw == 29 ? 29.97 : Double(framesRaw)
            guard fps > 0, ticksPerFrame > 0 else {
                throw SongImportError(byteOffset: 12, "invalid SMPTE timing in header")
            }
            smpteSecondsPerTick = 1 / (fps * Double(ticksPerFrame))
        } else {
            guard division > 0 else {
                throw SongImportError(byteOffset: 12, "header says 0 ticks per quarter note")
            }
            ticksPerQuarter = Int(division)
        }

        var parsed: [ParsedTrack] = []
        var warnings: [String] = []
        while reader.remaining > 0 {
            let chunkStart = reader.position
            guard reader.remaining >= 8 else {
                warnings.append("Ignored \(reader.remaining) stray bytes at the end of the file.")
                break
            }
            let id = try reader.fourCC()
            let length = Int(try reader.u32())
            guard length <= reader.remaining else {
                throw SongImportError(
                    byteOffset: chunkStart,
                    "track \(parsed.count + 1) is truncated (chunk says \(length) bytes, only \(reader.remaining) left)"
                )
            }
            let body = try reader.bytes(length)
            if id == "MTrk" {
                parsed.append(try parseTrack(body, index: parsed.count, fileOffset: chunkStart + 8))
            }
        }
        guard !parsed.isEmpty else {
            throw SongImportError("MIDI file has no tracks")
        }
        if parsed.count != declaredTracks {
            warnings.append("Header says \(declaredTracks) tracks but the file has \(parsed.count).")
        }

        let tempos = parsed.flatMap(\.tempos)
        let tempoMap: TempoMap
        if let smpteSecondsPerTick {
            tempoMap = TempoMap(secondsPerTick: smpteSecondsPerTick)
        } else {
            tempoMap = TempoMap(tempos: tempos, ticksPerQuarter: ticksPerQuarter ?? 480)
        }

        let tracks = parsed.enumerated().map { index, track -> Track in
            let channels = Set(track.notes.map(\.channel))
            return Track(
                id: index,
                name: track.name,
                noteCount: track.notes.count,
                channels: channels.map { $0 + 1 }.sorted(),
                lowestPitch: track.notes.map(\.pitch).min(),
                highestPitch: track.notes.map(\.pitch).max(),
                lyricCount: track.lyrics.count,
                isDrums: !channels.isEmpty && channels == [9]
            )
        }
        let title = parsed.first?.name.flatMap { $0.isEmpty ? nil : $0 }
        return MIDIFile(
            format: format,
            tracks: tracks,
            title: title,
            warnings: warnings,
            tempoMap: tempoMap,
            notesByTrack: parsed.map(\.notes),
            lyricsByTrack: parsed.map(\.lyrics),
            ticksPerQuarter: ticksPerQuarter
        )
    }

    private static func parseTrack(_ bytes: ArraySlice<UInt8>, index: Int, fileOffset: Int) throws -> ParsedTrack {
        var reader = ByteReader(Array(bytes), baseOffset: fileOffset)
        var track = ParsedTrack()
        var tick = 0
        var running: UInt8?
        // Open notes per channel/key, oldest first.
        var sounding: [Int: [(tick: Int, channel: Int, pitch: Int)]] = [:]

        func close(channel: Int, pitch: Int, at tick: Int) {
            let key = channel * 128 + pitch
            guard let started = sounding[key]?.first else { return }
            sounding[key]?.removeFirst()
            if tick > started.tick {
                track.notes.append(RawNote(start: started.tick, end: tick, pitch: pitch, channel: channel))
            }
        }

        while reader.remaining > 0 {
            let delta = try reader.vlq()
            tick += delta
            let eventOffset = reader.absolutePosition
            var status = try reader.peek()
            if status < 0x80 {
                guard let running else {
                    throw SongImportError(
                        byteOffset: eventOffset,
                        "track \(index + 1): data byte 0x\(String(status, radix: 16)) with no status (corrupt event)"
                    )
                }
                status = running
            } else {
                _ = try reader.u8()
            }

            switch status {
            case 0xFF:
                running = nil
                let type = try reader.u8()
                let length = try reader.vlq()
                let data = try reader.bytes(length)
                switch type {
                case 0x51:
                    guard data.count == 3 else {
                        throw SongImportError(byteOffset: eventOffset, "track \(index + 1): tempo event must be 3 bytes")
                    }
                    let micros = Int(data[data.startIndex]) << 16 | Int(data[data.startIndex + 1]) << 8 | Int(data[data.startIndex + 2])
                    // Under 50 000 µs per quarter (over 1200 BPM) is not a real tempo; ignoring it keeps the click
                    // track and timing sane.
                    if micros >= Self.minimumTempoMicros { track.tempos.append((tick, micros)) }
                case 0x03:
                    if track.name == nil {
                        track.name = TextDecoding.decode(Data(data)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case 0x05:
                    let rawText = TextDecoding.decode(Data(data))
                    let startsLine = rawText.hasPrefix("/") || rawText.hasPrefix("\\")
                    let text = rawText.trimmingCharacters(in: CharacterSet(charactersIn: "/\\\r\n"))
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        track.lyrics.append(Lyric(tick: tick, text: text, startsLine: startsLine))
                    }
                case 0x2F:
                    reader.skipToEnd()
                default:
                    break
                }
            case 0xF0, 0xF7:
                running = nil
                let length = try reader.vlq()
                try reader.skip(length)
            case 0xF1...0xFE:
                throw SongImportError(byteOffset: eventOffset, "track \(index + 1): unexpected system message 0x\(String(status, radix: 16))")
            default:
                running = status
                let kind = status & 0xF0
                let channel = Int(status & 0x0F)
                switch kind {
                case 0x80, 0x90:
                    let pitch = Int(try reader.dataByte())
                    let velocity = try reader.dataByte()
                    if kind == 0x90 && velocity > 0 {
                        // Re-striking a key that's already held many times over adds nothing singable.
                        let key = channel * 128 + pitch
                        if sounding[key, default: []].count < Self.maximumStackedStrikes {
                            sounding[key, default: []].append((tick, channel, pitch))
                        }
                    } else {
                        close(channel: channel, pitch: pitch, at: tick)
                    }
                    if track.notes.count > Self.maximumNotesPerTrack {
                        throw SongImportError(byteOffset: eventOffset, "track \(index + 1) has more than \(Self.maximumNotesPerTrack) notes")
                    }
                case 0xA0, 0xB0, 0xE0:
                    _ = try reader.dataByte()
                    _ = try reader.dataByte()
                default: // 0xC0 program change, 0xD0 channel pressure
                    _ = try reader.dataByte()
                }
            }
        }
        // Notes never switched off end with the track.
        for (_, stack) in sounding {
            for started in stack where tick > started.tick {
                track.notes.append(RawNote(start: started.tick, end: tick, pitch: started.pitch, channel: started.channel))
            }
        }
        track.notes.sort { ($0.start, -$0.pitch) < ($1.start, -$1.pitch) }
        return track
    }

    static let minimumTempoMicros = 50_000
    static let maximumStackedStrikes = 16
    static let maximumNotesPerTrack = 50_000

    /// Skyline: wherever notes overlap (including chords that start together), the highest sounding note wins,
    /// and a lower note resumes once the higher one ends. A note's first segment is its start, even when it begins
    /// under a higher note, so its lyric isn't lost.
    static func monophonic(_ input: [RawNote]) -> [Segment] {
        let notes = input
        let boundaries = Array(Set(notes.flatMap { [$0.start, $0.end] })).sorted()
        var segments: [Segment] = []
        // Active notes bucketed by pitch; ended notes are dropped lazily from the top bucket, so each sweep step
        // costs O(128 + bucket) instead of O(active notes).
        var buckets = [[Int]](repeating: [], count: 128)
        var started = Set<Int>()
        var next = 0
        for k in 0..<max(0, boundaries.count - 1) {
            let a = boundaries[k]
            let b = boundaries[k + 1]
            while next < notes.count, notes[next].start <= a {
                let pitch = notes[next].pitch
                if notes[next].end > a, (0..<128).contains(pitch) { buckets[pitch].append(next) }
                next += 1
            }
            var best: Int?
            var pitch = 127
            while pitch >= 0 {
                if !buckets[pitch].isEmpty {
                    buckets[pitch].removeAll { notes[$0].end <= a }
                    if let latest = buckets[pitch].max(by: { notes[$0].start < notes[$1].start }) {
                        best = latest
                        break
                    }
                }
                pitch -= 1
            }
            guard let best else { continue }
            if let last = segments.last, last.noteIndex == best, last.end == a {
                segments[segments.count - 1].end = b
            } else {
                let isStart = started.insert(best).inserted
                segments.append(Segment(
                    start: a, end: b, pitch: notes[best].pitch, noteIndex: best,
                    isNoteStart: isStart, noteStart: notes[best].start
                ))
            }
        }
        return segments
    }

    struct RawNote: Sendable, Equatable {
        var start: Int
        var end: Int
        var pitch: Int
        var channel: Int
    }

    struct Segment: Equatable {
        var start: Int
        var end: Int
        var pitch: Int
        var noteIndex: Int
        var isNoteStart: Bool
        /// Tick where the note itself began (the segment may begin later, once a higher note ends).
        var noteStart: Int
    }

    struct Lyric: Sendable {
        var tick: Int
        var text: String
        var startsLine: Bool
    }

    private struct ParsedTrack {
        var name: String?
        var notes: [RawNote] = []
        var tempos: [(tick: Int, micros: Int)] = []
        var lyrics: [Lyric] = []
    }
}

/// Ticks -> seconds, piecewise by tempo. Computes `ticks x secondsPerQuarter / ticksPerQuarter` so
/// whole-beat positions come out exact.
struct TempoMap: Sendable {
    private struct Point: Sendable {
        var tick: Int
        var seconds: Double
        var secondsPerQuarter: Double
    }

    private let points: [Point]
    private let ticksPerQuarter: Double

    init(tempos: [(tick: Int, micros: Int)], ticksPerQuarter: Int) {
        let tpq = Double(max(1, ticksPerQuarter))
        self.ticksPerQuarter = tpq
        var points: [Point] = []
        var current = Point(tick: 0, seconds: 0, secondsPerQuarter: 0.5)
        for tempo in tempos.sorted(by: { $0.tick < $1.tick }) {
            let seconds = current.seconds + Double(tempo.tick - current.tick) * current.secondsPerQuarter / tpq
            let point = Point(tick: tempo.tick, seconds: seconds, secondsPerQuarter: Double(tempo.micros) / 1_000_000)
            if tempo.tick != current.tick {
                points.append(current)
            }
            current = point
        }
        points.append(current)
        self.points = points
    }

    /// SMPTE timing: a fixed number of seconds per tick.
    init(secondsPerTick: Double) {
        ticksPerQuarter = 1
        points = [Point(tick: 0, seconds: 0, secondsPerQuarter: secondsPerTick)]
    }

    func seconds(at tick: Int) -> Double {
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if points[mid].tick <= tick { low = mid } else { high = mid - 1 }
        }
        let point = points[low]
        return point.seconds + Double(tick - point.tick) * point.secondsPerQuarter / ticksPerQuarter
    }

    /// Click grid: one click per quarter note (for SMPTE files, one every 0.5 s).
    var segments: [TempoSegment] {
        if ticksPerQuarter == 1, points.count == 1 {
            return [TempoSegment(start: 0, beatDuration: 0.5)]
        }
        return points.map { TempoSegment(start: $0.seconds, beatDuration: $0.secondsPerQuarter) }
    }
}

/// Bounds-checked big-endian reader; every overrun is a `SongImportError`, never a trap.
private struct ByteReader {
    private let storage: [UInt8]
    private(set) var position = 0
    private let baseOffset: Int

    init(_ bytes: [UInt8], baseOffset: Int = 0) {
        self.storage = bytes
        self.baseOffset = baseOffset
    }

    var remaining: Int { storage.count - position }
    var absolutePosition: Int { baseOffset + position }

    private func truncated() -> SongImportError {
        SongImportError(byteOffset: absolutePosition, "file ends unexpectedly (truncated or corrupt)")
    }

    func peek() throws -> UInt8 {
        guard position < storage.count else { throw truncated() }
        return storage[position]
    }

    mutating func u8() throws -> UInt8 {
        let value = try peek()
        position += 1
        return value
    }

    mutating func dataByte() throws -> UInt8 {
        let value = try u8()
        guard value < 0x80 else {
            throw SongImportError(byteOffset: absolutePosition - 1, "expected a data byte, found status 0x\(String(value, radix: 16))")
        }
        return value
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try u8()) << 8 | UInt16(try u8())
    }

    mutating func u32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = value << 8 | UInt32(try u8()) }
        return value
    }

    mutating func vlq() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try u8()
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw SongImportError(byteOffset: absolutePosition, "variable-length number is longer than 4 bytes")
    }

    mutating func fourCC() throws -> String {
        let chunk = try bytes(4)
        return String(decoding: chunk, as: UTF8.self)
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw truncated() }
        defer { position += count }
        return storage[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw truncated() }
        position += count
    }

    mutating func skipToEnd() {
        position = storage.count
    }
}
