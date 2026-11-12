#if canImport(SwiftUI)
import SwiftUI
import UIKit

struct LogsView: View {
    @State private var text = ""
    @State private var copied = false

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
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        text = AppLog.readAll()
    }

    private func copyAll() {
        reload()
        UIPasteboard.general.string = text
        AppLog.info("Logs copied to clipboard (\(text.count) chars)", category: "ui")
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
#endif
