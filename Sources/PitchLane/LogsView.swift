#if canImport(SwiftUI)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LogsView: View {
    @State private var text = ""
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                Button(copied ? "Copied" : "Copy All", systemImage: "doc.on.doc") { copyAll() }
                ShareLink("Share", item: text)
                Button("Clear", systemImage: "trash", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Clear the logs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                AppLog.clear()
                reload()
            }
        } message: {
            Text("Deletes the previous and current session logs from this phone.")
        }
        .onAppear { reload() }
    }

    private func reload() {
        text = AppLog.readAll()
    }

    private func copyAll() {
        reload()
        // Local only (not Universal Clipboard) and expires, so the log doesn't linger on other devices.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)]
        )
        AppLog.info("Logs copied to clipboard (\(text.count) chars)", category: "ui")
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
#endif
