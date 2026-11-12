#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import PitchLaneCore

/// What the detail sheet shows: a built-in kind (with its three difficulties) or one imported song.
enum LibrarySelection: Identifiable, Hashable {
    case builtIn(BuiltInKind)
    case imported(String)

    var id: String {
        switch self {
        case .builtIn(let kind): return "builtin:\(kind.rawValue)"
        case .imported(let id): return "imported:\(id)"
        }
    }
}

struct LibraryView: View {
    let title: String
    /// Called with the song to play and the chosen difficulty (nil = no Play button).
    var onPlay: ((Song, Difficulty) -> Void)?

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @State private var query = ""
    @State private var selection: LibrarySelection?
    @State private var showImporter = false

    static let importTypes: [UTType] = {
        var types: [UTType] = [.plainText, .midi, .mp3, .mpeg4Audio, .wav, .aiff, .audio]
        for ext in ["txt", "mid", "midi", "kar", "m4a"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        List {
            importedSection
            builtInSection(title: "Exercises", kinds: BuiltInKind.allCases.filter(\.isExercise))
            builtInSection(title: "Melodies", kinds: BuiltInKind.allCases.filter { !$0.isExercise })
            if !library.loadFailures.isEmpty {
                Section("Couldn't load") {
                    ForEach(library.loadFailures, id: \.folderName) { failure in
                        Text("\(failure.folderName): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search songs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import", systemImage: "plus") { showImporter = true }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                library.importFiles(urls)
            case .failure(let error):
                AppLog.warning("File picker failed: \(error.localizedDescription)", category: "library")
            }
        }
        .sheet(item: $selection) { selection in
            SongDetailSheet(selection: selection, onPlay: playHandler)
        }
        .sheet(item: $library.pendingMIDI) { pending in
            MIDITrackPicker(pending: pending)
        }
        .alert(
            library.message?.title ?? "",
            isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } }),
            presenting: library.message
        ) { _ in
            Button("OK") { library.message = nil }
        } message: { message in
            Text(message.text)
        }
        .onChange(of: query) { _, newValue in
            if !newValue.isEmpty { AppLog.debug("Library search \"\(newValue)\"", category: "library") }
        }
    }

    private var playHandler: ((Song, Difficulty) -> Void)? {
        guard let onPlay else { return nil }
        return { song, difficulty in
            selection = nil
            onPlay(song, difficulty)
        }
    }

    @ViewBuilder
    private var importedSection: some View {
        let songs = library.imported.filter { SongSearch.matches($0, query: query) }
        Section("Imported") {
            if library.imported.isEmpty {
                Text("Tap + to import UltraStar .txt or MIDI files from Files. Pick an .mp3, .m4a or .wav with it to add backing audio.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else if songs.isEmpty {
                Text("No imported songs match \"\(query)\".")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(songs) { song in
                Button {
                    selection = .imported(song.id)
                } label: {
                    SongRow(
                        title: song.title,
                        subtitle: [song.artist, song.source == .midi ? "MIDI" : "UltraStar"].filter { !$0.isEmpty }.joined(separator: " · "),
                        summary: song.summary,
                        accidentals: settings.settings.accidentals,
                        badge: song.backingAudioFile == nil ? nil : "music.note"
                    )
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    scores.forget(songID: songs[index].id)
                    library.delete(songs[index])
                }
            }
        }
    }

    @ViewBuilder
    private func builtInSection(title: String, kinds: [BuiltInKind]) -> some View {
        let visible = kinds.filter { kind in
            SongSearch.matches(BuiltInSongs.song(kind, .normal), query: query)
                || kind.subtitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if !visible.isEmpty {
            Section(title) {
                ForEach(visible) { kind in
                    Button {
                        selection = .builtIn(kind)
                    } label: {
                        SongRow(
                            title: kind.title,
                            subtitle: kind.subtitle + " · Easy / Normal / Hard",
                            summary: BuiltInSongs.song(kind, .normal).summary,
                            accidentals: settings.settings.accidentals,
                            badge: nil
                        )
                    }
                }
            }
        }
    }
}

struct SongRow: View {
    let title: String
    let subtitle: String
    let summary: SongSummary
    let accidentals: Accidentals
    let badge: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let badge {
                        Image(systemName: badge)
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(summary.durationText)
                    .font(.caption.monospacedDigit())
                Text(summary.rangeText(accidentals: accidentals))
                    .font(.caption)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .contentShape(Rectangle())
    }
}

struct SongDetailSheet: View {
    let selection: LibrarySelection
    var onPlay: ((Song, Difficulty) -> Void)?

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty: Difficulty = .normal
    @State private var showAudioImporter = false
    @State private var confirmDelete = false

    private var song: Song? {
        switch selection {
        case .builtIn(let kind): return BuiltInSongs.song(kind, difficulty)
        case .imported(let id): return library.imported.first { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let song {
                    form(for: song)
                } else {
                    Text("This song is no longer in the library.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationTitle(song?.title ?? "Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            difficulty = settings.settings.lastDifficulty
            AppLog.info("Song details opened: \(selection.id)", category: "library")
        }
    }

    private func form(for song: Song) -> some View {
        let summary = song.summary
        let accidentals = settings.settings.accidentals
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.title3.weight(.semibold))
                    if !song.artist.isEmpty {
                        Text(song.artist).foregroundStyle(Theme.textSecondary)
                    }
                    if case .builtIn(let kind) = selection {
                        Text(kind.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Section {
                Picker("Difficulty", selection: $difficulty) {
                    ForEach(Difficulty.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(difficultyHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let best = scores.best(songID: song.id, difficulty: difficulty) {
                    LabeledContent("Personal best", value: "\(best.score) · \(best.grade.rawValue) · \(Int((best.accuracy * 100).rounded()))%")
                }
            }
            Section("Song") {
                LabeledContent("Range", value: summary.rangeText(accidentals: accidentals))
                LabeledContent("Length", value: summary.durationText)
                LabeledContent("Notes", value: "\(summary.noteCount)")
                if summary.scoredNoteCount != summary.noteCount {
                    LabeledContent("Scored notes", value: "\(summary.scoredNoteCount)")
                }
                LabeledContent("Golden notes", value: "\(summary.goldenCount)")
                if song.source != .builtIn {
                    LabeledContent("Backing audio", value: song.backingAudioFile == nil ? "None" : "Attached")
                }
            }
            if onPlay != nil {
                Section("Game options") {
                    Toggle("Any octave counts", isOn: $settings.settings.octaveAgnostic)
                    Toggle("Click track", isOn: $settings.settings.clickTrack)
                    Toggle("Note names on notes", isOn: $settings.settings.showNoteNames)
                }
            }
            if let onPlay {
                Section {
                    Button {
                        settings.settings.lastDifficulty = difficulty
                        onPlay(song, difficulty)
                    } label: {
                        Label("Sing \(difficulty.displayName)", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
            if song.source != .builtIn {
                Section {
                    Button("Attach Backing Audio…", systemImage: "music.note") { showAudioImporter = true }
                    Button("Delete Song", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .aiff, .audio]) { result in
            if case .success(let url) = result {
                library.attachBackingAudio(url, to: song)
            }
        }
        .confirmationDialog("Delete \"\(song.title)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                scores.forget(songID: song.id)
                library.delete(song)
                dismiss()
            }
        }
    }

    private var difficultyHint: String {
        let tolerance = "on-pitch window ±\(Int(difficulty.toleranceCents)) cents"
        if case .builtIn = selection {
            switch difficulty {
            case .easy: return "Slower, narrower, even rhythm · \(tolerance)"
            case .normal: return "As written · \(tolerance)"
            case .hard: return "Faster, wider, ornamented · \(tolerance)"
            }
        }
        return "Scoring: \(tolerance)"
    }
}

struct MIDITrackPicker: View {
    let pending: LibraryModel.PendingMIDI

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick the track with the melody to sing. Chords are reduced to their highest note.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Section(pending.fileName) {
                    ForEach(pending.file.tracks.filter { $0.noteCount > 0 }) { track in
                        Button {
                            library.chooseMIDITrack(track.id)
                        } label: {
                            row(track)
                        }
                    }
                }
            }
            .navigationTitle("Choose Melody Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { library.cancelMIDIImport() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func row(_ track: MIDIFile.Track) -> some View {
        let accidentals = settings.settings.accidentals
        let range: String
        if let low = track.lowestPitch, let high = track.highestPitch {
            range = NoteNaming.name(forMIDINote: low, accidentals: accidentals) + "–" + NoteNaming.name(forMIDINote: high, accidentals: accidentals)
        } else {
            range = "–"
        }
        var details = ["\(track.noteCount) notes", range, "ch " + track.channels.map { String($0) }.joined(separator: ",")]
        if track.lyricCount > 0 { details.append("\(track.lyricCount) lyrics") }
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if track.isDrums {
                Text("Drums").font(.caption).foregroundStyle(Theme.warn)
            } else if track.id == pending.file.suggestedMelodyTrack {
                Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
