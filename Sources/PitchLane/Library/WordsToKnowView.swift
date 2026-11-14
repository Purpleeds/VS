#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Settings > Word predictor > Words to know: names, slang and unusual words the recogniser should listen for and the
/// word predictor should prefer (Core `WordModel.customWords`).
struct WordsToKnowView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var newWord = ""
    @FocusState private var typing: Bool

    var body: some View {
        let words = library.wordModel.customWords
        List {
            Section {
                HStack {
                    TextField("A name, word or short phrase", text: $newWord)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(WordModel.phraseKey(newWord).isEmpty)
                }
            } footer: {
                Text("Names, slang or made-up words in your songs, spelled the way you want them shown. PitchLane listens for them, and the word predictor uses them to fix words that sound like them, even when they were heard in pieces (\u{201C}beyond say\u{201D} becomes \u{201C}Beyonc\u{E9}\u{201D}).")
            }
            Section {
                if words.isEmpty {
                    Text("No words yet.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(words, id: \.self) { word in
                    Text(word)
                }
                .onDelete { offsets in
                    for index in offsets where index < words.count { library.removeWordToKnow(words[index]) }
                }
            } header: {
                Text("Your words (\(words.count) of \(WordModel.maxCustomWords))")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.4))
        .navigationTitle("Words to Know")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { AppLog.info("Words to know opened (\(words.count))", category: "ui") }
    }

    private func add() {
        guard !WordModel.phraseKey(newWord).isEmpty else { return }
        library.addWordToKnow(newWord)
        newWord = ""
        typing = true
    }
}
#endif
