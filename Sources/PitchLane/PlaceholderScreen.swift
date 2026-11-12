#if canImport(SwiftUI)
import SwiftUI

/// Empty stand-in screen used until each feature step lands.
struct PlaceholderScreen: View {
    let title: String
    let symbol: String
    let note: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlayView: View {
    var body: some View {
        PlaceholderScreen(title: "Play", symbol: "music.note", note: "Game screen (landscape). Coming soon.")
            .lockOrientation(.landscape)
    }
}

struct LibraryView: View {
    var body: some View {
        PlaceholderScreen(title: "Library", symbol: "books.vertical", note: "Songs will live here.")
    }
}

struct TunerView: View {
    var body: some View {
        PlaceholderScreen(title: "Tuner", symbol: "tuningfork", note: "Live pitch readout. Coming soon.")
    }
}
#endif
