import Foundation

/// Where removed items go. The app uses the real Trash; tests use a folder.
public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

public struct SystemTrasher: Trasher {
    public init() {}
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

public struct ItemOutcome: Sendable, Identifiable {
    public var id: UUID { finding.id }
    public let category: CategoryID
    public let finding: Finding
    /// Bytes freed, or freed once the Trash is emptied.
    public let bytes: Int64
    public let error: String?

    public var succeeded: Bool { error == nil }
    /// True when the space only comes back after emptying the Trash.
    public var waitsForTrash: Bool { category.action == .moveToTrash || category.action == .convertToHEVC }
}

public enum Cleaner {
    /// Cleans the given findings in category order. Nothing is ever deleted
    /// permanently except unavailable simulators, which `simctl` removes.
    public static func run(
        _ categories: [ScanCategory],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trasher: Trasher = SystemTrasher(),
        progress: @escaping @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void = { _, _, _ in }
    ) async -> CleanupReport {
        let started = Date()
        let diskBefore = DiskStatus.current(home: home)
        let order = CategoryID.allCases
        let work = categories
            .sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
            .flatMap { c in c.findings.map { (c.id, $0) } }

        // Checked again here, not only at scan time: links may have appeared since.
        var links: LinkIndex?
        if work.contains(where: { $0.0.action == .moveToTrash }) {
            progress(0, work.count, "링크 확인 중…")
            links = LinkIndex.build(home: home)
        }

        var outcomes: [ItemOutcome] = []
        for (index, (category, finding)) in work.enumerated() {
            progress(index, work.count, finding.url.lastPathComponent)
            do {
                if category.action == .moveToTrash, let l = links?.incomingLink(into: finding.url) {
                    throw RoomyError.linked(l.link)
                }
                let bytes = try await clean(finding, as: category, home: home, trasher: trasher)
                outcomes.append(ItemOutcome(category: category, finding: finding, bytes: bytes, error: nil))
            } catch {
                outcomes.append(ItemOutcome(category: category, finding: finding, bytes: 0,
                                            error: error.localizedDescription))
            }
        }
        progress(work.count, work.count, "")
        return CleanupReport(startedAt: started, finishedAt: Date(), outcomes: outcomes,
                             diskBefore: diskBefore, diskAfter: DiskStatus.current(home: home))
    }

    static func clean(_ f: Finding, as category: CategoryID, home: URL, trasher: Trasher) async throws -> Int64 {
        switch category.action {
        case .moveToTrash:
            try SafetyGuard.validate(f.url, home: home)
            guard FileSystem.exists(f.url) else { throw RoomyError.missing(f.url.path) }
            let size = FileSystem.allocatedSize(f.url)
            try trasher.trash(f.url)
            return size

        case .deleteSimulator:
            guard let udid = f.token, let simctl = Shell.simctlPath() else {
                throw RoomyError.system("Xcode를 찾을 수 없어요.")
            }
            let size = FileSystem.allocatedSize(f.url)
            _ = try Shell.run(simctl, ["delete", udid])
            return size

        case .cloneDuplicate:
            guard let original = f.original else { throw RoomyError.missing(f.url.path) }
            try SafetyGuard.validate(f.url, home: home)
            let size = FileSystem.allocatedSize(f.url)
            try Duplicates.replaceWithClone(f.url, original: original)
            return size

        case .convertToHEVC:
            try SafetyGuard.validate(f.url, home: home)
            return try await Videos.convertToHEVC(f.url, trasher: trasher)
        }
    }
}
