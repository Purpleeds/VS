#if canImport(SwiftUI)
import Foundation
import SwiftUI
import PitchLaneCore

/// Built-in songs plus imported ones (stored under Application Support/PitchLane/Songs).
@MainActor
final class LibraryModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var text: String
    }

    /// A MIDI file waiting for the user to choose its melody track.
    struct PendingMIDI: Identifiable {
        let id = UUID()
        var file: MIDIFile
        var fileName: String
        var data: Data
        /// Temporary copy of backing audio picked together with the file.
        var audio: URL?
    }

    @Published private(set) var imported: [Song] = []
    @Published private(set) var loadFailures: [SongLibraryStore.LoadFailure] = []
    @Published var message: Message?
    @Published var pendingMIDI: PendingMIDI?

    /// A video being turned into a song (notes transcribed from its singing).
    struct Transcription: Equatable {
        var title: String
        var progress: Double
        var queued: Int
    }

    @Published private(set) var transcription: Transcription?
    @Published private(set) var songJob: SongJob?
    private var songJobTask: Task<Void, Never>?
    private var transcriptionQueue: [(url: URL, title: String)] = []
    private var transcriptionTask: Task<Void, Never>?

    let builtIns = BuiltInSongs.all
    private let store = SongLibraryStore(root: AppPaths.songsDirectory)
    private var midiQueue: [PendingMIDI] = []
    /// An import report held back while MIDI track pickers are showing (an alert and a sheet can't appear
    /// together); shown once the last picker closes.
    private var deferredMessage: Message?

    static let songExtensions: Set<String> = ["txt", "mid", "midi", "kar"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf"]
    private static let maxSongFileBytes = 2 * 1_024 * 1_024
    /// Temporary copies of audio picked with a song; wiped at launch and as soon as they're attached.
    private static let importTempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PitchLaneImport", isDirectory: true)

    init() {
        try? FileManager.default.removeItem(at: Self.importTempDirectory)
        reload()
    }

    /// Romaji of Japanese titles (and artists), so they can be found by typing or saying them in Latin letters.
    private(set) var romajiNames: [String: String] = [:]

    /// Search that also matches the romaji of Japanese titles.
    func matches(_ song: Song, query: String) -> Bool {
        if SongSearch.matches(song, query: query) { return true }
        guard let romaji = romajiNames[song.id] else { return false }
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            romaji.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func reload() {
        let result = store.loadAll()
        imported = result.songs
        var names: [String: String] = [:]
        for song in result.songs {
            let parts = [LyricRomanizer.romanize(song.title), LyricRomanizer.romanize(song.artist)].compactMap { $0 }
            if !parts.isEmpty { names[song.id] = parts.joined(separator: " ") }
        }
        romajiNames = names
        loadFailures = result.failures
        for failure in result.failures {
            AppLog.error("Couldn't load song folder \(failure.folderName): \(failure.message)", category: "library")
        }
    }

    func song(withID id: String) -> Song? {
        BuiltInSongs.song(withID: id) ?? imported.first { $0.id == id }
    }

    func backingAudioURL(for song: Song) -> URL? {
        song.source == .builtIn ? nil : store.backingAudioURL(for: song)
    }

    func videoURL(for song: Song) -> URL? {
        song.source == .builtIn ? nil : store.videoURL(for: song)
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        AppLog.info("Import started: \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))", category: "library")
        var songFiles: [(name: String, data: Data)] = []
        var audioFiles: [(name: String, url: URL)] = []
        var videoCopies: Set<URL> = []
        var problems: [String] = []

        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if Self.songExtensions.contains(ext) {
                    // Check the size before reading, so a huge file is never loaded into memory.
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= Self.maxSongFileBytes else {
                        problems.append("\(name): file is too large for a song (\(size / 1_024) KB, limit \(Self.maxSongFileBytes / 1_024) KB)")
                        continue
                    }
                    let data = try Data(contentsOf: url)
                    guard data.count <= Self.maxSongFileBytes else {
                        problems.append("\(name): file is too large for a song (\(data.count / 1_024) KB)")
                        continue
                    }
                    songFiles.append((name, data))
                } else if Self.audioExtensions.contains(ext) || VideoTools.extensions.contains(ext) {
                    try FileManager.default.createDirectory(at: Self.importTempDirectory, withIntermediateDirectories: true)
                    let temp = Self.importTempDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: url, to: temp)
                    audioFiles.append((name, temp))
                    if VideoTools.extensions.contains(ext) { videoCopies.insert(temp) }
                } else {
                    problems.append("\(name): not a supported file (use .txt, .mid, .midi, .mp3, .m4a, .wav or a video)")
                }
            } catch {
                problems.append("\(name): couldn't be read (\(error.localizedDescription))")
            }
        }

        // Videos picked without a song file become new songs, transcribed from their singing.
        var transcribing: Set<URL> = []
        if songFiles.isEmpty {
            for file in audioFiles where videoCopies.contains(file.url) {
                transcribing.insert(file.url)
                transcriptionQueue.append((file.url, URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent))
            }
            if audioFiles.contains(where: { !videoCopies.contains($0.url) }) {
                problems.append("Audio files need a song: pick them together with a .txt or MIDI file, or use Attach Backing Audio in a song's details.")
            }
        }

        var importedTitles: [String] = []
        for file in songFiles {
            let audio = matchAudio(for: file, among: audioFiles, songFileCount: songFiles.count)
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            let title = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
            do {
                if ext == "txt" {
                    let result = try UltraStarImporter.parse(data: file.data, fallbackTitle: title)
                    let audioURL = audio ?? result.audioReference.flatMap { reference in
                        audioFiles.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }?.url
                    }
                    problems += try save(result.song, fileName: file.name, data: file.data, audio: audioURL)
                    importedTitles.append(result.song.title)
                    problems += result.warnings.map { "\(file.name): \($0)" }
                } else {
                    let midi = try MIDIFile.parse(file.data)
                    problems += midi.warnings.map { "\(file.name): \($0)" }
                    let playable = midi.tracks.filter { $0.noteCount > 0 }
                    if playable.count == 1, let only = playable.first {
                        let song = try midi.song(track: only.id, title: midi.title ?? title)
                        problems += try save(song, fileName: file.name, data: file.data, audio: audio)
                        importedTitles.append(song.title)
                    } else if playable.isEmpty {
                        throw SongImportError("MIDI file has no notes")
                    } else {
                        midiQueue.append(PendingMIDI(file: midi, fileName: file.name, data: file.data, audio: audio))
                    }
                }
            } catch {
                let text = (error as? SongImportError)?.description ?? error.localizedDescription
                problems.append("\(file.name): \(text)")
                AppLog.warning("Import failed for \(file.name): \(text)", category: "library")
            }
        }

        // Temp audio copies are only kept while a queued MIDI import still needs them.
        let stillNeeded = Set(midiQueue.compactMap(\.audio) + [pendingMIDI?.audio].compactMap { $0 })
        for file in audioFiles where !stillNeeded.contains(file.url) && !transcribing.contains(file.url) {
            try? FileManager.default.removeItem(at: file.url)
        }

        reload()
        report(imported: importedTitles, problems: problems)
        presentNextMIDI()
        runNextTranscription()
    }

    // MARK: Video

    /// A video from Photos (already copied to the import folder): make a new song from its singing.
    func makeSong(fromPhotosVideo movie: PickedMovie) {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        transcriptionQueue.append((movie.url, "Video \(formatter.string(from: Date()))"))
        AppLog.info("Video from Photos queued for transcription", category: "library")
        runNextTranscription()
    }

    func cancelTranscription() {
        guard let task = transcriptionTask else { return }
        AppLog.info("Transcription cancelled by the user (\(transcriptionQueue.count) more queued, dropped)", category: "library")
        for job in transcriptionQueue { try? FileManager.default.removeItem(at: job.url) }
        transcriptionQueue.removeAll()
        task.cancel()
    }

    private func runNextTranscription() {
        guard transcriptionTask == nil, !transcriptionQueue.isEmpty else { return }
        let job = transcriptionQueue.removeFirst()
        transcription = Transcription(title: job.title, progress: 0, queued: transcriptionQueue.count)
        transcriptionTask = Task { [weak self] in
            await self?.transcribe(job)
            guard let self else { return }
            self.transcriptionTask = nil
            self.transcription = nil
            self.runNextTranscription()
        }
    }

    private func transcribe(_ job: (url: URL, title: String)) async {
        defer { try? FileManager.default.removeItem(at: job.url) }
        let started = Date()
        AppLog.info("Transcribing a video (\(job.url.pathExtension))", category: "library")
        do {
            let notes = try await VideoTools.transcribe(job.url) { [weak self] fraction in
                Task { @MainActor in self?.transcription?.progress = fraction }
            }
            try Task.checkCancellation()
            guard notes.count >= 3 else {
                AppLog.warning("Transcription found \(notes.count) notes", category: "library")
                show(Message(
                    title: "No singing found",
                    text: "PitchLane couldn't hear a clear sung melody in \"\(job.title)\". Videos of one voice (with little music behind it) work best."
                ))
                return
            }
            let song = Song(
                id: UUID().uuidString,
                title: SongLimits.clip(job.title),
                source: .video,
                notes: notes,
                lineBreaks: MelodyTranscriber.lineBreaks(for: notes)
            )
            try store.save(song)
            let withVideo = try store.attachVideo(from: job.url, to: song)
            let backingProblem = await extractBacking(for: withVideo)
            reload()
            let summary = withVideo.summary
            AppLog.info(
                "Made \"\(song.title)\" from a video: \(notes.count) notes, \(summary.durationText), range \(summary.rangeText(accidentals: .sharps)), "
                    + "\(String(format: "%.1f", Date().timeIntervalSince(started))) s",
                category: "library"
            )
            var text = "\(notes.count) notes from the singing (\(summary.rangeText(accidentals: .sharps))). The video plays behind the lane and its sound is the backing track.\n\nAdd the words with Find Lyrics Online in the song's details. Transcriptions are rough, especially with music behind the voice; try it in Practice first."
            if let backingProblem { text += "\n\n" + backingProblem }
            show(Message(title: "Made \"\(song.title)\"", text: text))
        } catch is CancellationError {
            AppLog.info("Transcription cancelled", category: "library")
        } catch {
            AppLog.warning("Transcription failed: \(error.localizedDescription)", category: "library")
            show(Message(title: "Couldn't make a song from the video", text: error.localizedDescription))
        }
    }

    /// Puts the song's video soundtrack in as its backing audio. Returns a problem to show, if any.
    private func extractBacking(for song: Song) async -> String? {
        guard let video = store.videoURL(for: song) else { return nil }
        try? FileManager.default.createDirectory(at: Self.importTempDirectory, withIntermediateDirectories: true)
        let temp = Self.importTempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await VideoTools.extractAudio(from: video, to: temp)
            let latest = store.loadAll().songs.first { $0.id == song.id } ?? song
            let updated = try store.attachBackingAudio(from: temp, to: latest)
            AppLog.info("Video sound attached as backing for \"\(song.title)\" (\(updated.backingAudioFile ?? "?"))", category: "library")
            return nil
        } catch {
            AppLog.warning("Video sound couldn't become backing audio: \(error.localizedDescription)", category: "library")
            return "The video's sound couldn't be used as backing audio (\(error.localizedDescription))."
        }
    }

    /// Attaches a video (and its sound as backing audio) to an existing song. `url` is a file this app may read
    /// (a Files pick under security scope, or a Photos copy in the import folder, deleted afterwards if `owned`).
    func attachVideo(_ url: URL, to song: Song, owned: Bool) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            if owned { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let updated = try store.attachVideo(from: url, to: song)
            AppLog.info("Attached video to \"\(song.title)\" as \(updated.videoFile ?? "?")", category: "library")
            reload()
            Task {
                let problem = await extractBacking(for: updated)
                reload()
                message = Message(
                    title: "Video added",
                    text: problem ?? "It plays behind the lane, and its sound is now this song's backing audio."
                )
            }
        } catch {
            AppLog.warning("Attach video failed: \(error.localizedDescription)", category: "library")
            message = Message(title: "Couldn't add the video", text: error.localizedDescription)
        }
    }

    /// Shows the message now, or after the MIDI pickers if one is up or queued.
    private func show(_ newMessage: Message) {
        if pendingMIDI != nil || !midiQueue.isEmpty {
            deferredMessage = newMessage
        } else {
            message = newMessage
        }
    }

    private func discardTempAudio(_ url: URL?) {
        guard let url else { return }
        let stillNeeded = midiQueue.contains { $0.audio == url } || pendingMIDI?.audio == url
        if !stillNeeded { try? FileManager.default.removeItem(at: url) }
    }

    func chooseMIDITrack(_ track: Int) {
        guard let pending = pendingMIDI else { return }
        pendingMIDI = nil
        defer { discardTempAudio(pending.audio) }
        let title = pending.file.title ?? URL(fileURLWithPath: pending.fileName).deletingPathExtension().lastPathComponent
        do {
            let song = try pending.file.song(track: track, title: title)
            let problems = try save(song, fileName: pending.fileName, data: pending.data, audio: pending.audio)
            AppLog.info("MIDI track \(track + 1) chosen for \(pending.fileName)", category: "library")
            reload()
            report(imported: [song.title], problems: problems)
        } catch {
            let text = (error as? SongImportError)?.description ?? error.localizedDescription
            AppLog.warning("MIDI import failed for \(pending.fileName): \(text)", category: "library")
            report(imported: [], problems: ["\(pending.fileName): \(text)"])
        }
        presentNextMIDI()
    }

    func cancelMIDIImport() {
        if let pending = pendingMIDI {
            AppLog.info("MIDI import cancelled for \(pending.fileName)", category: "library")
            pendingMIDI = nil
            discardTempAudio(pending.audio)
        }
        presentNextMIDI()
    }

    private func presentNextMIDI() {
        guard pendingMIDI == nil else { return }
        if !midiQueue.isEmpty {
            pendingMIDI = midiQueue.removeFirst()
        } else if let deferred = deferredMessage {
            deferredMessage = nil
            message = deferred
        }
    }

    /// Audio chosen with the song: same base name, or the only audio file when only one song was picked.
    private func matchAudio(for file: (name: String, data: Data), among audio: [(name: String, url: URL)], songFileCount: Int) -> URL? {
        let base = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent.lowercased()
        if let sameName = audio.first(where: { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent.lowercased() == base }) {
            return sameName.url
        }
        return songFileCount == 1 && audio.count == 1 ? audio[0].url : nil
    }

    /// Saves the song, then attaches audio. A failed attach is a warning: the song itself was imported.
    @discardableResult
    private func save(_ song: Song, fileName: String, data: Data, audio: URL?) throws -> [String] {
        try store.save(song, originalFileName: fileName, originalData: data)
        var saved = song
        var problems: [String] = []
        if let audio, VideoTools.isVideo(audio) {
            do {
                saved = try store.attachVideo(from: audio, to: song)
                let withVideo = saved
                Task {
                    if let problem = await extractBacking(for: withVideo) { show(Message(title: "Backing audio", text: "\(fileName): \(problem)")) }
                    reload()
                }
            } catch {
                AppLog.warning("Video for \(fileName) couldn't be attached: \(error.localizedDescription)", category: "library")
                problems.append("\(fileName): imported, but the video couldn't be added (\(error.localizedDescription)).")
            }
        } else if let audio {
            do {
                saved = try store.attachBackingAudio(from: audio, to: song)
            } catch {
                AppLog.warning("Backing audio for \(fileName) couldn't be attached: \(error.localizedDescription)", category: "library")
                problems.append("\(fileName): imported, but the backing audio couldn't be added (\(error.localizedDescription)). Use Attach Backing Audio in the song's details.")
            }
        }
        let summary = saved.summary
        AppLog.info(
            "Imported \"\(saved.title)\" from \(fileName): \(summary.noteCount) notes, \(summary.durationText), "
                + "range \(summary.rangeText(accidentals: .sharps)), backing audio \(saved.backingAudioFile ?? "none")",
            category: "library"
        )
        return problems
    }

    private func report(imported titles: [String], problems: [String]) {
        guard !titles.isEmpty || !problems.isEmpty else { return }
        let title: String
        if problems.isEmpty {
            title = titles.count == 1 ? "Imported \"\(titles[0])\"" : "Imported \(titles.count) songs"
        } else if titles.isEmpty {
            title = "Import failed"
        } else {
            title = "Imported \(titles.count), with problems"
        }
        show(Message(title: title, text: problems.isEmpty ? "Ready to sing." : problems.joined(separator: "\n\n")))
    }

    // MARK: Edit

    func attachBackingAudio(_ url: URL, to song: Song) {
        if VideoTools.isVideo(url) {
            attachVideo(url, to: song, owned: false)
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let updated = try store.attachBackingAudio(from: url, to: song)
            AppLog.info("Attached backing audio \(url.lastPathComponent) to \"\(song.title)\" as \(updated.backingAudioFile ?? "?")", category: "library")
            reload()
            message = Message(title: "Backing audio added", text: url.lastPathComponent)
        } catch {
            AppLog.warning("Attach audio failed: \(error.localizedDescription)", category: "library")
            message = Message(title: "Couldn't add audio", text: error.localizedDescription)
        }
    }

    /// Removes every imported song (built-ins are untouched). Returns the ids that were removed.
    @discardableResult
    func deleteAllImported() -> [String] {
        let ids = imported.map(\.id)
        for id in ids {
            do {
                try store.delete(id: id)
            } catch {
                AppLog.error("Delete failed for \(id): \(error.localizedDescription)", category: "library")
            }
        }
        AppLog.info("Deleted all imported songs (\(ids.count))", category: "library")
        reload()
        return ids
    }

    // MARK: Lyrics

    /// Lyrics picked from LRCLIB. With `listen`, the words are timed by listening to the song first.
    func applyLyrics(_ candidate: LyricsCandidate, to song: Song, listen: Bool) {
        applyLyrics(synced: candidate.syncedLyrics, plain: candidate.plainLyrics, credit: "LRCLIB: \(candidate.credit)", to: song, listen: listen)
    }

    /// Lyrics typed or pasted by the user (plain text, or LRC with time tags).
    func applyPastedLyrics(_ text: String, to song: Song, listen: Bool) {
        let timed = LRCParser.parse(text).filter { !$0.words.isEmpty }.count >= 2
        applyLyrics(synced: timed ? text : nil, plain: timed ? nil : text, credit: "Your lyrics", to: song, listen: listen)
    }

    private func applyLyrics(synced: String?, plain: String?, credit: String, to song: Song, listen: Bool) {
        let current = imported.first { $0.id == song.id } ?? song
        let audio = store.stemURLs(for: current)?.vocals ?? store.backingAudioURL(for: current)
        guard listen, let audio, songJobTask == nil else {
            finishLyrics(synced: synced, plain: plain, credit: credit, songID: song.id, heard: nil, listenProblem: nil)
            return
        }
        let words = lyricLines(synced: synced, plain: plain).flatMap { $0 }
        let script = LyricScript.detect([synced ?? plain ?? ""])
        let hints: [String]
        if script != .other {
            // Whole words help the Japanese, Korean or Chinese recogniser more than single syllables.
            let text = (synced.map { LRCParser.parse($0).map(\.text).joined(separator: "\n") } ?? plain) ?? ""
            hints = Array(Set(LyricRomanizer.hintWords(text, script: script))).sorted()
        } else {
            hints = Array(Set(words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count > 2 })).sorted()
        }
        let locale = script.speechLocaleIdentifier.map { Locale(identifier: $0) } ?? Locale.current
        songJob = SongJob(songID: song.id, title: "Listening to the song to time the words…", progress: 0)
        AppLog.info("Listening to a song to time \(words.count) lyric words (\(current.hasStems ? "voice stem" : "full mix"))", category: "lyrics")
        songJobTask = Task { [weak self] in
            var heard: [LyricListenMatcher.HeardWord]?
            var problem: String?
            do {
                heard = try await SongListener.heardWords(in: audio, locale: locale, hints: hints) { [weak self] fraction in
                    Task { @MainActor in self?.songJob?.progress = fraction }
                }
            } catch is CancellationError {
                self?.endSongJob()
                return
            } catch {
                problem = error.localizedDescription
                AppLog.warning("Listening for lyrics failed: \(error.localizedDescription)", category: "lyrics")
            }
            self?.endSongJob()
            self?.finishLyrics(synced: synced, plain: plain, credit: credit, songID: song.id, heard: heard, listenProblem: problem)
        }
    }

    /// Lyric lines as words, or as hiragana morae for Japanese (one sung beat per note).
    private func lyricLines(synced: String?, plain: String?) -> [[String]] {
        if let synced {
            let lines = japaneseAware(LRCParser.parse(synced)).filter { !$0.words.isEmpty }.map { $0.words.map(\.text) }
            if lines.count >= 2 { return lines }
        }
        let text = plain ?? synced ?? ""
        let script = LyricScript.detect([text])
        guard script != .other else { return LyricListenMatcher.lines(from: text) }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
            .map { LyricRomanizer.units($0, script: script) }
            .filter { !$0.isEmpty }
    }

    /// Timed lines in Japanese, Korean or Chinese become lines of sung units (morae / syllables / characters), with
    /// no word times, spread over the line's notes.
    private func japaneseAware(_ lines: [LyricLine]) -> [LyricLine] {
        let script = LyricScript.detect(lines.map(\.text))
        guard script != .other else { return lines }
        return lines.map { line in
            guard line.text.unicodeScalars.contains(where: LyricScript.isSyllabic) else { return line }
            return LyricLine(time: line.time, text: line.text,
                             words: LyricRomanizer.units(line.text, script: script).map { LyricLine.Word(time: nil, text: $0) })
        }
    }

    /// Heard words split into the same units, so they match the lyrics unit by unit.
    private func japaneseAware(_ heard: [LyricListenMatcher.HeardWord]) -> [LyricListenMatcher.HeardWord] {
        LyricRomanizer.units(heard, script: LyricScript.detect(heard.map(\.text)))
    }

    /// Picks the best timing source (listening, then the lyrics' own timing, then phrases), fits and saves.
    private func finishLyrics(synced: String?, plain: String?, credit: String, songID: String, heard: [LyricListenMatcher.HeardWord]?, listenProblem: String?) {
        guard let current = imported.first(where: { $0.id == songID }) else { return }
        let timedLines = japaneseAware(synced.map { LRCParser.parse($0) } ?? [])
        let hasTiming = timedLines.filter { !$0.words.isEmpty }.count >= 2
        var result: LyricAligner.Result?
        var how: String?
        if let heard {
            let match = LyricListenMatcher.match(lyrics: lyricLines(synced: synced, plain: plain), heard: japaneseAware(heard))
            let enough = match.matchedWords >= 3 && match.matchedFraction >= (hasTiming ? 0.25 : 0.12)
            AppLog.info(
                "Listening heard \(heard.count) words; matched \(match.matchedWords)/\(match.totalWords) lyric words (\(enough ? "used" : "not enough"))",
                category: "lyrics"
            )
            if enough {
                result = LyricAligner.apply(lines: match.lines, to: current, autoOffset: false)
                how = "Timed by listening to the song: recognised \(match.matchedWords) of \(match.totalWords) words."
            } else {
                how = "Listening to the song only recognised \(match.matchedWords) of \(match.totalWords) words, so "
                    + (hasTiming ? "the lyrics' own timing was used." : "the lines were spread over the song's phrases.")
            }
        } else if let listenProblem {
            how = "Couldn't listen to the song (\(listenProblem)), so " + (hasTiming ? "the lyrics' own timing was used." : "the lines were spread over the song's phrases.")
        }
        if result == nil {
            if hasTiming {
                result = LyricAligner.apply(lines: timedLines, to: current)
            } else {
                result = LyricAligner.applyPlain(lines: lyricLines(synced: nil, plain: plain ?? synced ?? ""), to: current)
            }
        }
        guard let result else { return }
        AppLog.info(
            "Lyrics fitted: \(result.wordsPlaced)/\(result.wordsTotal) words on \(result.notesWithWords)/\(current.notes.count) notes, "
                + "offset \(String(format: "%+.2f", result.offset)) s",
            category: "lyrics"
        )
        guard result.wordsPlaced > 0 else {
            message = Message(title: "The words didn't fit", text: "None of the lyrics lined up with this song's notes. Try other lyrics.")
            return
        }
        var updated = result.song
        updated.lyricsCredit = SongLimits.clip(credit)
        do {
            try store.save(updated)
            reload()
            var text = "\(result.wordsPlaced) words placed on \(result.notesWithWords) of \(current.notes.count) notes."
            if let how { text += " " + how }
            if abs(result.offset) >= 0.05 {
                text += " The lyrics were shifted \(String(format: "%+.1f", result.offset)) s to match your recording."
            }
            if result.wordsPlaced < result.wordsTotal {
                text += " \(result.wordsTotal - result.wordsPlaced) words had no notes to go on."
            }
            message = Message(title: "Lyrics added", text: text)
        } catch {
            message = Message(title: "Couldn't save the lyrics", text: error.localizedDescription)
        }
    }

    // MARK: Voice and music

    /// A long job on one song (separating stems, listening for lyrics), shown in its sheet.
    struct SongJob: Equatable {
        var songID: String
        var title: String
        var progress: Double
    }

    func stems(for song: Song) -> BackingStems? {
        guard song.source != .builtIn, let urls = store.stemURLs(for: song),
              FileManager.default.fileExists(atPath: urls.vocals.path),
              FileManager.default.fileExists(atPath: urls.music.path) else { return nil }
        return BackingStems(vocals: urls.vocals, music: urls.music)
    }

    func separateStems(for song: Song) {
        guard songJobTask == nil, let backing = store.backingAudioURL(for: song) else { return }
        songJob = SongJob(songID: song.id, title: "Separating the voice from the music…", progress: 0)
        AppLog.info("Separating voice and music", category: "stems")
        songJobTask = Task { [weak self] in
            await self?.runSeparation(songID: song.id, backing: backing)
            self?.endSongJob()
        }
    }

    private func runSeparation(songID: String, backing: URL) async {
        try? FileManager.default.createDirectory(at: Self.importTempDirectory, withIntermediateDirectories: true)
        let vocals = Self.importTempDirectory.appendingPathComponent("\(UUID().uuidString)-vocals.m4a")
        let music = Self.importTempDirectory.appendingPathComponent("\(UUID().uuidString)-music.m4a")
        defer {
            try? FileManager.default.removeItem(at: vocals)
            try? FileManager.default.removeItem(at: music)
        }
        let started = Date()
        do {
            try await StemMaker.separate(backing, vocalsOut: vocals, musicOut: music) { [weak self] fraction in
                Task { @MainActor in self?.songJob?.progress = fraction }
            }
            guard let latest = store.loadAll().songs.first(where: { $0.id == songID }) else { return }
            _ = try store.attachStems(vocals: vocals, music: music, to: latest)
            reload()
            AppLog.info("Stems ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s", category: "stems")
            message = Message(
                title: "Voice and music separated",
                text: "Use the Singer's voice and Music sliders (here or in the pause menu) to keep a little of the voice or the music in the background. It works best when the singer is in the middle of a stereo mix; some drums and echo can stay with the voice."
            )
        } catch is CancellationError {
            AppLog.info("Separation cancelled", category: "stems")
        } catch {
            AppLog.warning("Separation failed: \(error.localizedDescription)", category: "stems")
            message = Message(title: "Couldn't separate this song", text: error.localizedDescription)
        }
    }

    func removeStems(from song: Song) {
        do {
            _ = try store.removeStems(from: imported.first { $0.id == song.id } ?? song)
            AppLog.info("Stems removed", category: "stems")
            reload()
        } catch {
            message = Message(title: "Couldn't remove the separation", text: error.localizedDescription)
        }
    }

    func cancelSongJob() {
        songJobTask?.cancel()
    }

    private func endSongJob() {
        songJobTask = nil
        songJob = nil
    }

    /// Erase everything: also removes folders that never loaded (corrupt or half-written imports).
    func eraseSongStorage() {
        do {
            if FileManager.default.fileExists(atPath: AppPaths.songsDirectory.path) {
                try FileManager.default.removeItem(at: AppPaths.songsDirectory)
            }
        } catch {
            AppLog.error("Couldn't remove the songs folder: \(error.localizedDescription)", category: "library")
        }
        reload()
    }

    @discardableResult
    func delete(_ song: Song) -> Bool {
        guard song.source != .builtIn else { return false }
        defer { reload() }
        do {
            try store.delete(id: song.id)
            AppLog.info("Deleted \"\(song.title)\"", category: "library")
            return true
        } catch {
            AppLog.error("Delete failed for \(song.id): \(error.localizedDescription)", category: "library")
            message = Message(title: "Couldn't delete", text: error.localizedDescription)
            return false
        }
    }
}
#endif
