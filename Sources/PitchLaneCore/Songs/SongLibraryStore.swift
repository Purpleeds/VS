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

    /// The song's folder. An id that isn't a plain folder name (e.g. from a hand-edited `song.json`) maps to a
    /// harmless name, so it can never point outside `root`.
    public func folder(for id: String) -> URL {
        root.appendingPathComponent(Self.isSafeFolderName(id) ? id : "invalid-id", isDirectory: true)
    }

    public static func isSafeFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.hasPrefix(".") && name.utf8.count <= 128
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
                if var song = try JSONFileStore<Song>(url: url).load() {
                    // The folder is the identity: never trust an id edited into song.json.
                    song.id = name
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
        guard Self.isSafeFolderName(song.id) else { throw SongImportError("song id \"\(song.id)\" isn't a valid folder name") }
        // Encode first, so a song that can't be written never leaves a half-made folder behind.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(song)
        let fileManager = FileManager.default
        let folder = folder(for: song.id)
        let existed = fileManager.fileExists(atPath: folder.path)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if let originalData {
                let ext = originalFileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "dat"
                let safeExt = ext.isEmpty || !Self.isSafeFolderName(ext) ? "dat" : ext
                try originalData.write(to: folder.appendingPathComponent("original.\(safeExt)"), options: .atomic)
            }
            try json.write(to: folder.appendingPathComponent(Self.songFileName), options: .atomic)
        } catch {
            if !existed { try? fileManager.removeItem(at: folder) }
            throw error
        }
    }

    /// Copies an audio file into the song's folder as `backing.<ext>` (replacing any previous one) and saves.
    @discardableResult
    public func attachBackingAudio(from source: URL, to song: Song) throws -> Song {
        let fileManager = FileManager.default
        let folder = folder(for: song.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let name = "backing.\(ext.isEmpty || !Self.isSafeFolderName(ext) ? "audio" : ext)"
        let destination = folder.appendingPathComponent(name)
        // Copy next to the destination first: if the copy fails (disk full, unreadable source) the old backing
        // audio and song.json are untouched.
        let staging = folder.appendingPathComponent("backing.incoming-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        var updated = song
        updated.backingAudioFile = name
        // Stems were made from the old backing: they no longer match.
        let staleStems = stemURLs(for: song)
        updated.vocalsStemFile = nil
        updated.musicStemFile = nil
        try save(updated)
        if let old = backingAudioURL(for: song), old.lastPathComponent != name, fileManager.fileExists(atPath: old.path) {
            try? fileManager.removeItem(at: old)
        }
        if let staleStems {
            try? fileManager.removeItem(at: staleStems.vocals)
            try? fileManager.removeItem(at: staleStems.music)
        }
        return updated
    }

    public static let vocalsStemName = "stem-vocals.m4a"
    public static let musicStemName = "stem-music.m4a"

    public func stemURLs(for song: Song) -> (vocals: URL, music: URL)? {
        guard let vocals = song.vocalsStemFile, let music = song.musicStemFile else { return nil }
        let folder = folder(for: song.id)
        return (folder.appendingPathComponent(vocals), folder.appendingPathComponent(music))
    }

    /// Moves freshly separated stems into the song's folder and saves. The sources are consumed.
    @discardableResult
    public func attachStems(vocals: URL, music: URL, to song: Song) throws -> Song {
        let fileManager = FileManager.default
        let folder = folder(for: song.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let vocalsTarget = folder.appendingPathComponent(Self.vocalsStemName)
        let musicTarget = folder.appendingPathComponent(Self.musicStemName)
        for (source, target) in [(vocals, vocalsTarget), (music, musicTarget)] {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: target)
            }
        }
        var updated = song
        updated.vocalsStemFile = Self.vocalsStemName
        updated.musicStemFile = Self.musicStemName
        try save(updated)
        return updated
    }

    @discardableResult
    public func removeStems(from song: Song) throws -> Song {
        let urls = stemURLs(for: song)
        var updated = song
        updated.vocalsStemFile = nil
        updated.musicStemFile = nil
        try save(updated)
        if let urls {
            try? FileManager.default.removeItem(at: urls.vocals)
            try? FileManager.default.removeItem(at: urls.music)
        }
        return updated
    }

    public func videoURL(for song: Song) -> URL? {
        song.videoFile.map { folder(for: song.id).appendingPathComponent($0) }
    }

    /// Copies a video into the song's folder as `video.<ext>` (replacing any previous one) and saves.
    /// Same safety as backing audio: the old file and `song.json` stay untouched if the copy fails.
    @discardableResult
    public func attachVideo(from source: URL, to song: Song) throws -> Song {
        let fileManager = FileManager.default
        let folder = folder(for: song.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let name = "video.\(ext.isEmpty || !Self.isSafeFolderName(ext) ? "mov" : ext)"
        let destination = folder.appendingPathComponent(name)
        let staging = folder.appendingPathComponent("video.incoming-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        var updated = song
        updated.videoFile = name
        try save(updated)
        if let old = videoURL(for: song), old.lastPathComponent != name, fileManager.fileExists(atPath: old.path) {
            try? fileManager.removeItem(at: old)
        }
        return updated
    }

    public func delete(id: String) throws {
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}
