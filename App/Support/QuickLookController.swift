import AppKit
import ParseleyCore
import Quartz

/// Quick Look for a clip: writes its text to a temporary file with a fitting extension
/// (.json, .csv, .tsv, .txt) so the system previewer formats it, and shows the standard
/// Quick Look panel. The file is deleted when the preview closes.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var fileURL: URL?
    /// When the preview was opened: the history panel loses focus a moment before Quick
    /// Look's window counts as visible, and must not close in between.
    private var openedAt: Date?

    var isVisible: Bool {
        if let openedAt, Date().timeIntervalSince(openedAt) < 1 { return true }
        return QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func preview(text: String, kind: ClipKind) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Parseley Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Clip.\(Self.fileExtension(for: text, kind: kind))")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
            return
        }
        cleanUp()
        fileURL = url
        openedAt = Date()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        // Quick Look needs the app to be active to show its panel; the paste target was
        // remembered when the history panel opened, so ↩ still pastes in the right app.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        openedAt = nil
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
        cleanUp()
    }

    static func fileExtension(for text: String, kind: ClipKind) -> String {
        switch kind {
        case .json: return "json"
        case .table: return text.contains("\t") ? "tsv" : "csv"
        default:
            if let table = DataTable.parse(text), table.delimiter == .comma { return "csv" }
            return "txt"
        }
    }

    private func cleanUp() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { fileURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard let url = fileURL else { return nil }
            return url as NSURL
        }
    }
}
