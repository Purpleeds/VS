import Foundation

/// Imported songs on disk: one folder per song under `root`, holding `song.json`, a copy of the original
/// file and optionally the backing audio. Folders are scanned on load, so there is no index to drift.
public struct SongLibraryStore: Sendable {
    public struct LoadFailure: Sendable, Equatable {
        public var folderName: String
        public var message: String
    }

    public static let songFileName = "song.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func backingAudioURL(for song: Song) -> URL? {
        song.backingAudioFile.map { folder(for: song.id).appendingPathComponent($0) }
    }

    /// All readable songs (sorted by title) plus a failure for each folder that couldn't be read.
    public func loadAll() -> (songs: [Song], failures: [LoadFailure]) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return ([], [])
        }
        var songs: [Song] = []
        var failures: [LoadFailure] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder(for: name).appendingPathComponent(Self.songFileName)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                if let song = try JSONFileStore<Song>(url: url).load() {
                    songs.append(song)
                }
            } catch {
                failures.append(LoadFailure(folderName: name, message: "\(error)"))
            }
        }
        songs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return (songs, failures)
    }

    /// Writes `song.json`, plus the original file if given. Creates the folder.
    public func save(_ song: Song, originalFileName: String? = nil, originalData: Data? = nil) throws {
        let folder = folder(for: song.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let originalData {
            let ext = originalFileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "dat"
            try originalData.write(to: folder.appendingPathComponent("original.\(ext.isEmpty ? "dat" : ext)"), options: .atomic)
        }
        try JSONFileStore<Song>(url: folder.appendingPathComponent(Self.songFileName)).save(song)
    }

    /// Copies an audio file into the song's folder as `backing.<ext>` (replacing any previous one) and saves.
    @discardableResult
    public func attachBackingAudio(from source: URL, to song: Song) throws -> Song {
        let fileManager = FileManager.default
        let folder = folder(for: song.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = backingAudioURL(for: song), fileManager.fileExists(atPath: old.path) {
            try fileManager.removeItem(at: old)
        }
        let ext = source.pathExtension.lowercased()
        let name = "backing.\(ext.isEmpty ? "audio" : ext)"
        let destination = folder.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        var updated = song
        updated.backingAudioFile = name
        try save(updated)
        return updated
    }

    public func delete(id: String) throws {
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}
