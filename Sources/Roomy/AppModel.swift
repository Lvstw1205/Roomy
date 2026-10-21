import AppKit
import Observation
import RoomyCore
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    enum Phase { case idle, scanning, results, cleaning, report }

    var phase = Phase.idle
    var disk = DiskStatus.current()
    var status = ""
    var progress = 0.0
    var categories: [ScanCategory] = []
    var enabled: Set<CategoryID> = []
    var excluded: Set<UUID> = []
    var report: CleanupReport?
    var scanSeconds = 0.0

    /// What the clean button will act on: enabled categories minus unticked items.
    var selection: [ScanCategory] {
        categories
            .filter { enabled.contains($0.id) }
            .map { c in ScanCategory(id: c.id, findings: c.findings.filter { !excluded.contains($0.id) }) }
            .filter { !$0.findings.isEmpty }
    }

    var selectedBytes: Int64 { selection.reduce(0) { $0 + $1.totalBytes } }
    var selectedCount: Int { selection.reduce(0) { $0 + $1.findings.count } }
    var foundBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }

    func scan() {
        phase = .scanning
        status = "스캔 준비 중…"
        excluded = []
        Task {
            let result = await Task.detached {
                await Scanner.scan(ScanOptions()) { message in
                    Task { @MainActor in self.status = message }
                }
            }.value
            categories = result.categories
            enabled = Set(result.categories.map(\.id).filter(\.enabledByDefault))
            disk = result.disk
            scanSeconds = result.duration
            phase = .results
        }
    }

    func clean() {
        let plan = selection
        phase = .cleaning
        progress = 0
        Task {
            let report = await Task.detached {
                await Cleaner.run(plan) { done, total, current in
                    Task { @MainActor in
                        self.progress = total > 0 ? Double(done) / Double(total) : 1
                        self.status = current
                    }
                }
            }.value
            self.report = report
            disk = report.diskAfter
            phase = .report
        }
    }

    func toggle(_ id: CategoryID) {
        if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
    }

    func toggle(_ finding: Finding) {
        if excluded.contains(finding.id) { excluded.remove(finding.id) } else { excluded.insert(finding.id) }
    }

    func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Roomy-보고서-\(report.startedAt.formatted(.iso8601.year().month().day())).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension URL {
    /// Path with the home folder shortened to ~.
    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
