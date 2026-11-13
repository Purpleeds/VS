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

    let builtIns = BuiltInSongs.all
    private let store = SongLibraryStore(root: AppPaths.songsDirectory)
    private var midiQueue: [PendingMIDI] = []

    static let songExtensions: Set<String> = ["txt", "mid", "midi", "kar"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf"]
    private static let maxSongFileBytes = 10 * 1_024 * 1_024

    init() {
        reload()
    }

    func reload() {
        let result = store.loadAll()
        imported = result.songs
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

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        AppLog.info("Import started: \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))", category: "library")
        var songFiles: [(name: String, data: Data)] = []
        var audioFiles: [(name: String, url: URL)] = []
        var problems: [String] = []

        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if Self.songExtensions.contains(ext) {
                    let data = try Data(contentsOf: url)
                    guard data.count <= Self.maxSongFileBytes else {
                        problems.append("\(name): file is too large for a song (\(data.count / 1_024) KB)")
                        continue
                    }
                    songFiles.append((name, data))
                } else if Self.audioExtensions.contains(ext) {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: url, to: temp)
                    audioFiles.append((name, temp))
                } else {
                    problems.append("\(name): not a supported file (use .txt, .mid, .midi, .mp3, .m4a or .wav)")
                }
            } catch {
                problems.append("\(name): couldn't be read (\(error.localizedDescription))")
            }
        }

        if songFiles.isEmpty, !audioFiles.isEmpty {
            problems.append("Audio files need a song: pick them together with a .txt or MIDI file, or use Attach Backing Audio in a song's details.")
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
                    try save(result.song, fileName: file.name, data: file.data, audio: audioURL)
                    importedTitles.append(result.song.title)
                    problems += result.warnings.map { "\(file.name): \($0)" }
                } else {
                    let midi = try MIDIFile.parse(file.data)
                    problems += midi.warnings.map { "\(file.name): \($0)" }
                    let playable = midi.tracks.filter { $0.noteCount > 0 }
                    if playable.count == 1, let only = playable.first {
                        let song = try midi.song(track: only.id, title: midi.title ?? title)
                        try save(song, fileName: file.name, data: file.data, audio: audio)
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

        reload()
        report(imported: importedTitles, problems: problems)
        presentNextMIDI()
    }

    func chooseMIDITrack(_ track: Int) {
        guard let pending = pendingMIDI else { return }
        pendingMIDI = nil
        let title = pending.file.title ?? URL(fileURLWithPath: pending.fileName).deletingPathExtension().lastPathComponent
        do {
            let song = try pending.file.song(track: track, title: title)
            try save(song, fileName: pending.fileName, data: pending.data, audio: pending.audio)
            AppLog.info("MIDI track \(track + 1) chosen for \(pending.fileName)", category: "library")
            reload()
            report(imported: [song.title], problems: [])
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
        }
        pendingMIDI = nil
        presentNextMIDI()
    }

    private func presentNextMIDI() {
        guard pendingMIDI == nil, !midiQueue.isEmpty else { return }
        pendingMIDI = midiQueue.removeFirst()
    }

    /// Audio chosen with the song: same base name, or the only audio file when only one song was picked.
    private func matchAudio(for file: (name: String, data: Data), among audio: [(name: String, url: URL)], songFileCount: Int) -> URL? {
        let base = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent.lowercased()
        if let sameName = audio.first(where: { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent.lowercased() == base }) {
            return sameName.url
        }
        return songFileCount == 1 && audio.count == 1 ? audio[0].url : nil
    }

    private func save(_ song: Song, fileName: String, data: Data, audio: URL?) throws {
        try store.save(song, originalFileName: fileName, originalData: data)
        var saved = song
        if let audio {
            saved = try store.attachBackingAudio(from: audio, to: song)
        }
        let summary = saved.summary
        AppLog.info(
            "Imported \"\(saved.title)\" from \(fileName): \(summary.noteCount) notes, \(summary.durationText), "
                + "range \(summary.rangeText(accidentals: .sharps)), backing audio \(saved.backingAudioFile ?? "none")",
            category: "library"
        )
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
        message = Message(title: title, text: problems.isEmpty ? "Ready to sing." : problems.joined(separator: "\n\n"))
    }

    // MARK: Edit

    func attachBackingAudio(_ url: URL, to song: Song) {
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

    func delete(_ song: Song) {
        guard song.source != .builtIn else { return }
        do {
            try store.delete(id: song.id)
            AppLog.info("Deleted \"\(song.title)\"", category: "library")
        } catch {
            AppLog.error("Delete failed for \(song.id): \(error.localizedDescription)", category: "library")
            message = Message(title: "Couldn't delete", text: error.localizedDescription)
        }
        reload()
    }
}
#endif
