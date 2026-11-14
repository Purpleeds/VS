#if canImport(SwiftUI)
import PhotosUI
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
    /// Called with the song to play and the chosen plan (nil = no Play button).
    var onPlay: ((Song, GamePlan) -> Void)?

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @State private var query = ""
    @State private var selection: LibrarySelection?
    @State private var showImporter = false
    @State private var pendingDelete: Song?
    @State private var showPhotos = false
    @State private var photosItem: PhotosPickerItem?
    @State private var showVoice = false
    @State private var voiceSelection: LibrarySelection?

    static let importTypes: [UTType] = {
        var types: [UTType] = [.plainText, .midi, .mp3, .mpeg4Audio, .wav, .aiff, .audio] + VideoTools.contentTypes
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
                    Text("\(library.loadFailures.count == 1 ? "A song" : "\(library.loadFailures.count) songs") couldn't be read (the file may be damaged). The details are in Settings > Logs; Erase everything in Settings removes them.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
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
                Button("Search by Voice", systemImage: "mic") { showVoice = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Song or Video from Files…", systemImage: "folder") { showImporter = true }
                    Button("Video from Photos…", systemImage: "photo.on.rectangle") { showPhotos = true }
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photosItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            photosItem = nil
            Task { await loadPhotosVideo(item) { library.makeSong(fromPhotosVideo: $0) } }
        }
        .sheet(isPresented: $showVoice, onDismiss: {
            if let found = voiceSelection {
                voiceSelection = nil
                selection = found
            }
        }) {
            VoiceSearchSheet(prompt: "Say a song name", hints: voiceCandidates.map(\.title)) { spoken in
                handleVoice(spoken)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let job = library.transcription {
                TranscriptionCard(job: job) { library.cancelTranscription() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: library.transcription != nil)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                library.importFiles(urls)
            case .failure(let error):
                AppLog.warning("File picker failed: \(error.localizedDescription)", category: "library")
                library.message = .init(title: "Couldn't open Files", text: error.localizedDescription)
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
            // While the song sheet is up, it shows the message itself (an alert can't appear behind a sheet).
            isPresented: Binding(get: { library.message != nil && selection == nil }, set: { if !$0 { library.message = nil } }),
            presenting: library.message
        ) { _ in
            Button("OK") { library.message = nil }
        } message: { message in
            Text(message.text)
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { song in
            Button("Delete", role: .destructive) {
                // Delete first: if that fails, the scores stay with the song.
                if library.delete(song) { scores.forget(songID: song.id) }
                pendingDelete = nil
            }
        } message: { _ in
            Text("The song, its backing audio, scores and history are removed from this phone.")
        }
    }

    private var voiceCandidates: [VoiceQuery.Candidate] {
        BuiltInKind.allCases.map { VoiceQuery.Candidate(id: "builtin:\($0.rawValue)", title: $0.title) }
            + library.imported.map { VoiceQuery.Candidate(id: $0.id, title: $0.title, artist: $0.artist) }
    }

    /// Spoken words: fill the search field, and open the song when one clearly matches.
    private func handleVoice(_ spoken: String) {
        query = spoken
        guard let match = VoiceQuery.bestMatch(for: spoken, in: voiceCandidates) else {
            AppLog.info("Voice search: no single match, showing search results", category: "voice")
            return
        }
        AppLog.info("Voice search: opened a song (score \(String(format: "%.2f", match.score)))", category: "voice")
        if match.id.hasPrefix("builtin:"), let kind = BuiltInKind(rawValue: String(match.id.dropFirst("builtin:".count))) {
            voiceSelection = .builtIn(kind)
        } else {
            voiceSelection = .imported(match.id)
        }
    }

    private var playHandler: ((Song, GamePlan) -> Void)? {
        guard let onPlay else { return nil }
        return { song, plan in
            selection = nil
            onPlay(song, plan)
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
                        subtitle: [song.artist, song.sourceName].filter { !$0.isEmpty }.joined(separator: " · "),
                        summary: song.summary,
                        accidentals: settings.settings.accidentals,
                        badge: song.videoFile != nil ? "film" : (song.backingAudioFile == nil ? nil : "music.note")
                    )
                }
            }
            .onDelete { offsets in
                if let index = offsets.first { pendingDelete = songs[index] }
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
    var onPlay: ((Song, GamePlan) -> Void)?

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty: Difficulty = .normal
    @State private var shift = 0
    @State private var practice = PracticeOptions.normal
    @State private var showAudioImporter = false
    @State private var showPhotos = false
    @State private var photosItem: PhotosPickerItem?
    @State private var showLyrics = false
    @State private var pickedLyrics: LyricsCandidate?
    @State private var showPaste = false
    @State private var pastedLyrics: String?
    @State private var listenForTiming = true
    @State private var confirmRemoveStems = false
    @State private var confirmDelete = false
    @StateObject private var preview = TransposePreview()

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
        .onDisappear { preview.stop() }
        .onAppear {
            difficulty = settings.settings.lastDifficulty
            shift = settings.settings.transpose(for: shiftKey)
            AppLog.info("Song details opened: \(selection.id)", category: "library")
        }
        .onChange(of: difficulty) { _, _ in
            // Built-ins are different songs per difficulty, so their loop points no longer apply. Imported songs
            // are the same notes at every difficulty: keep the loop (and the toggle stays in sync).
            if case .builtIn = selection {
                practice = PracticeOptions(speed: practice.speed, noFail: practice.noFail)
            }
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
        .onChange(of: shift) { _, newValue in
            settings.settings.setTranspose(newValue, for: shiftKey)
        }
    }

    /// Built-ins keep one shift across their difficulties.
    private var shiftKey: String {
        switch selection {
        case .builtIn(let kind): return "builtin.\(kind.rawValue)"
        case .imported(let id): return id
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
                    LabeledContent("Video", value: song.videoFile == nil ? "None" : (settings.settings.showVideo ? "Plays behind the lane" : "Attached (hidden in Settings)"))
                    if let credit = song.lyricsCredit {
                        LabeledContent("Lyrics", value: credit)
                    }
                }
            }
            if onPlay != nil {
                TransposeSection(song: song, shift: $shift, preview: preview)
                PracticeSection(song: song, practice: $practice)
                    .id(song.id)
                Section("Game options") {
                    Toggle("Guide tone (\(difficulty == .hard ? "Hard" : "Easy & Normal"))", isOn: Binding(
                        get: { settings.settings.guideEnabled(for: difficulty) },
                        set: { settings.settings.setGuide($0, for: difficulty) }
                    ))
                    Toggle("Any octave counts", isOn: $settings.settings.octaveAgnostic)
                    Toggle("Click track", isOn: $settings.settings.clickTrack)
                    if song.videoFile != nil {
                        Toggle("Video behind the lane", isOn: $settings.settings.showVideo)
                    }
                    Toggle("Note names on notes", isOn: $settings.settings.showNoteNames)
                }
            }
            if let onPlay {
                Section {
                    Button {
                        preview.stop()
                        settings.settings.lastDifficulty = difficulty
                        onPlay(song, GamePlan(difficulty: difficulty, transpose: shift, practice: practice))
                    } label: {
                        Label("\(practice.isPractice ? "Practice" : "Sing") \(difficulty.displayName)", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
            if song.source != .builtIn {
                lyricsSection(song)
                if song.backingAudioFile != nil {
                    voiceAndMusicSection(song)
                }
                Section {
                    Button("Attach Audio or Video from Files…", systemImage: "music.note") { showAudioImporter = true }
                    Button("Attach Video from Photos…", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("Delete Song", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let job = library.songJob, job.songID == song.id {
                JobCard(title: job.title, progress: job.progress) { library.cancelSongJob() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showPaste, onDismiss: {
            if let text = pastedLyrics {
                pastedLyrics = nil
                library.applyPastedLyrics(text, to: song, listen: listenForTiming && song.backingAudioFile != nil)
            }
        }) {
            PasteLyricsSheet { pastedLyrics = $0 }
        }
        .confirmationDialog("Remove the voice/music separation?", isPresented: $confirmRemoveStems, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { library.removeStems(from: song) }
        } message: {
            Text("The song goes back to its original backing audio. You can separate it again any time.")
        }
        .photosPicker(isPresented: $showPhotos, selection: $photosItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            photosItem = nil
            Task { await loadPhotosVideo(item) { library.attachVideo($0.url, to: song, owned: true) } }
        }
        .sheet(isPresented: $showLyrics, onDismiss: {
            if let candidate = pickedLyrics {
                pickedLyrics = nil
                library.applyLyrics(candidate, to: song, listen: listenForTiming && song.backingAudioFile != nil)
            }
        }) {
            LyricsSearchSheet(song: song, backingURL: library.backingAudioURL(for: song)) { pickedLyrics = $0 }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .aiff, .audio] + VideoTools.contentTypes) { result in
            if case .success(let url) = result {
                library.attachBackingAudio(url, to: song)
            }
        }
        .confirmationDialog("Delete \"\(song.title)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if library.delete(song) { scores.forget(songID: song.id) }
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func lyricsSection(_ song: Song) -> some View {
        let busy = library.songJob != nil
        Section {
            Button("Find Lyrics Online…", systemImage: "text.quote") { showLyrics = true }
                .disabled(busy)
            Button("Type or Paste Lyrics…", systemImage: "doc.on.clipboard") { showPaste = true }
                .disabled(busy)
            if song.backingAudioFile != nil {
                Toggle("Time the words by listening to the song", isOn: $listenForTiming)
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text(song.backingAudioFile == nil
                 ? "Lines are matched to the notes by their timing, or spread over the song's phrases."
                 : "Listening uses on-device speech recognition on the song\(song.hasStems ? "'s separated voice" : "") to find when each word is sung. Nothing is sent anywhere. Singing is harder to recognise than speech, so it falls back to the lyrics' own timing when too few words are heard.")
        }
    }

    @ViewBuilder
    private func voiceAndMusicSection(_ song: Song) -> some View {
        Section {
            if song.hasStems {
                VolumeSlider(title: "Singer's voice", symbol: "music.mic", value: $settings.settings.voiceStemVolume)
                VolumeSlider(title: "Music", symbol: "guitars", value: $settings.settings.musicStemVolume)
                HStack {
                    Button("Just the music") {
                        settings.settings.voiceStemVolume = 0.1
                        settings.settings.musicStemVolume = 1
                    }
                    Spacer()
                    Button("Original") {
                        settings.settings.voiceStemVolume = 1
                        settings.settings.musicStemVolume = 1
                    }
                    Spacer()
                    Button("Mostly voice") {
                        settings.settings.voiceStemVolume = 1
                        settings.settings.musicStemVolume = 0.2
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Remove Separation", systemImage: "arrow.uturn.backward", role: .destructive) { confirmRemoveStems = true }
                    .disabled(library.songJob != nil)
            } else {
                Button("Separate Voice and Music", systemImage: "slider.horizontal.2.square") { library.separateStems(for: song) }
                    .disabled(library.songJob != nil)
            }
        } header: {
            Text("Voice and music")
        } footer: {
            Text(song.hasStems
                 ? "These levels apply to every separated song, and you can change them in the pause menu while you sing."
                 : "Splits the backing into the singer's voice and the music, on this phone, so you can keep a little of either in the background. Works best on stereo recordings with the singer in the middle; it takes about a tenth of the song's length.")
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
/// Loads a Photos video into the import folder and hands it on; failures go to the library's message.
@MainActor
func loadPhotosVideo(_ item: PhotosPickerItem, then use: (PickedMovie) -> Void) async {
    do {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
            AppLog.warning("Photos video: nothing loaded", category: "library")
            return
        }
        AppLog.info("Photos video loaded (\(movie.url.pathExtension))", category: "library")
        use(movie)
    } catch {
        AppLog.warning("Photos video couldn't be loaded: \(error.localizedDescription)", category: "library")
    }
}

/// Progress of turning a video into a song.
struct TranscriptionCard: View {
    let job: LibraryModel.Transcription
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 6) {
                Text("Listening to \"\(job.title)\"…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                ProgressView(value: job.progress)
                    .tint(Theme.accent)
                Text(job.queued > 0 ? "\(Int(job.progress * 100))% · \(job.queued) more queued" : "\(Int(job.progress * 100))% · writing notes from the singing")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension Song {
    /// Where the song came from, for list subtitles.
    var sourceName: String {
        switch source {
        case .builtIn: return "Built-in"
        case .ultraStar: return "UltraStar"
        case .midi: return "MIDI"
        case .video: return "From video"
        }
    }
}
/// Progress of a long job on one song, with Cancel.
struct JobCard: View {
    let title: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text("\(Int(progress * 100))% · keep PitchLane open")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Type or paste lyrics (plain lines, or LRC with [mm:ss] times).
struct PasteLyricsSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.body)
                } footer: {
                    Text("One line per sung line. Lines with [mm:ss] times keep their timing. The words stay on this phone.")
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
