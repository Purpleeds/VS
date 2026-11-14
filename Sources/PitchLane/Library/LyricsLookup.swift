#if canImport(SwiftUI)
import AVFoundation
import SwiftUI
import PitchLaneCore

/// The only network call in the app: a lyrics search on LRCLIB. Sends just the query text.
enum LyricsService {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func search(_ query: String, songDuration: Double?) async throws -> [LyricsCandidate] {
        guard let url = LyricsSearch.searchURL(query: query) else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("PitchLane/\(BuildInfo.current.version) (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(errorDescription: "No answer from lrclib.net.") }
        guard http.statusCode == 200 else {
            throw Failure(errorDescription: "lrclib.net answered with error \(http.statusCode). Try again later.")
        }
        return try LyricsSearch.decode(data, songDuration: songDuration)
    }
}

/// Find lyrics for a song by name (typed or spoken) and pick a match; the words are then placed on its notes.
struct LyricsSearchSheet: View {
    let song: Song
    let backingURL: URL?
    let onPick: (LyricsCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LyricsCandidate] = []
    @State private var searching = false
    @State private var searched = false
    @State private var errorText: String?
    @State private var showVoice = false
    @State private var spoken: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Song title and artist", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                        Button {
                            showVoice = true
                        } label: {
                            Image(systemName: "mic.fill")
                        }
                        .accessibilityLabel("Say the song name")
                        .buttonStyle(.borderless)
                    }
                    Button {
                        search()
                    } label: {
                        Label(searching ? "Searching…" : "Search", systemImage: "magnifyingglass")
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                } footer: {
                    Text("Only this text is sent, to lrclib.net (a free, open database of timed lyrics). The words are fitted to your notes on the phone\(song.notes.contains { !$0.displayLyric.isEmpty } ? " and replace the song's current words" : "").")
                }

                if searching {
                    HStack {
                        ProgressView()
                        Text("Looking up lyrics…").foregroundStyle(Theme.textSecondary)
                    }
                } else if let errorText {
                    Label(errorText, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Theme.warn)
                } else if searched, results.isEmpty {
                    Text("No lyrics found. Try the exact title and the artist's name.")
                        .foregroundStyle(Theme.textSecondary)
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { candidate in
                            Button {
                                onPick(candidate)
                                dismiss()
                            } label: {
                                ResultRow(candidate: candidate)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GameBackdrop(intensity: 0.5))
            .navigationTitle("Find Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showVoice, onDismiss: {
                if let spoken, !spoken.isEmpty {
                    query = spoken
                    search()
                }
                spoken = nil
            }) {
                VoiceSearchSheet(prompt: "Say the song and artist", hints: [song.title]) { spoken = $0 }
            }
        }
        .onAppear {
            if query.isEmpty { query = [song.title, song.artist].filter { !$0.isEmpty }.joined(separator: " ") }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !searching else { return }
        searching = true
        errorText = nil
        Task {
            defer { searching = false }
            var duration: Double?
            if let backingURL {
                duration = try? await AVURLAsset(url: backingURL).load(.duration).seconds
            }
            do {
                results = try await LyricsService.search(text, songDuration: duration ?? (song.duration > 0 ? song.duration : nil))
                searched = true
                AppLog.info("Lyrics search: \(results.count) usable results (\(results.filter(\.hasSyncedLyrics).count) timed)", category: "lyrics")
            } catch {
                results = []
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppLog.warning("Lyrics search failed: \(error.localizedDescription)", category: "lyrics")
            }
        }
    }
}

private struct ResultRow: View {
    let candidate: LyricsCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(candidate.trackName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(details)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Label(candidate.hasSyncedLyrics ? "Timed lyrics" : "Words only (spread over your phrases)",
                  systemImage: candidate.hasSyncedLyrics ? "clock.badge.checkmark" : "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(candidate.hasSyncedLyrics ? Theme.good : Theme.warn)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [candidate.artistName]
        if let album = candidate.albumName, !album.isEmpty { parts.append(album) }
        if let duration = candidate.duration {
            let total = Int(duration.rounded())
            parts.append("\(total / 60):\(String(format: "%02d", total % 60))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
#endif
