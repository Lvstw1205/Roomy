import Foundation

public struct CleanupReport: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let outcomes: [ItemOutcome]
    public let diskBefore: DiskStatus
    public let diskAfter: DiskStatus

    public var failures: [ItemOutcome] { outcomes.filter { !$0.succeeded } }
    /// Space that is free right now (clones, deleted simulators).
    public var freedNowBytes: Int64 { sum { $0.succeeded && !$0.waitsForTrash } }
    /// Space that comes back once the Trash is emptied.
    public var inTrashBytes: Int64 { sum { $0.succeeded && $0.waitsForTrash } }
    public var totalBytes: Int64 { freedNowBytes + inTrashBytes }

    func sum(_ include: (ItemOutcome) -> Bool) -> Int64 {
        outcomes.filter(include).reduce(0) { $0 + $1.bytes }
    }

    public struct Line: Sendable, Identifiable {
        public var id: CategoryID { category }
        public let category: CategoryID
        public let succeeded: Int
        public let failed: Int
        public let bytes: Int64
    }

    public var lines: [Line] {
        CategoryID.allCases.compactMap { c in
            let items = outcomes.filter { $0.category == c }
            guard !items.isEmpty else { return nil }
            let ok = items.filter(\.succeeded)
            return Line(category: c, succeeded: ok.count, failed: items.count - ok.count,
                        bytes: ok.reduce(0) { $0 + $1.bytes })
        }
    }

    public func markdown() -> String {
        let date = startedAt.formatted(date: .long, time: .shortened)
        let seconds = Int(finishedAt.timeIntervalSince(startedAt))
        var md = """
        # Roomy 정리 보고서

        \(date) · \(seconds)초 걸림

        | | |
        |---|---|
        | 확보한 공간 (합계) | **\(totalBytes.formattedBytes)** |
        | 바로 확보됨 | \(freedNowBytes.formattedBytes) |
        | 휴지통을 비우면 확보됨 | \(inTrashBytes.formattedBytes) |
        | 정리 전 남은 공간 | \(diskBefore.availableBytes.formattedBytes) |
        | 정리 후 남은 공간 | \(diskAfter.availableBytes.formattedBytes) |

        ## 항목별 결과

        | 항목 | 처리 | 실패 | 용량 |
        |---|---:|---:|---:|

        """
        for l in lines {
            md += "| \(l.category.title) | \(l.succeeded) | \(l.failed) | \(l.bytes.formattedBytes) |\n"
        }
        md += "\n## 처리한 파일\n\n"
        for o in outcomes where o.succeeded {
            md += "- \(o.category.title): `\(o.finding.url.path)` (\(o.bytes.formattedBytes))\n"
        }
        if !failures.isEmpty {
            md += "\n## 건너뛴 항목\n\n"
            for o in failures {
                md += "- `\(o.finding.url.path)`: \(o.error ?? "")\n"
            }
        }
        if inTrashBytes > 0 {
            md += "\n> 휴지통으로 옮긴 파일은 휴지통을 비워야 공간이 생겨요. 그 전까지는 언제든 되돌릴 수 있어요.\n"
        }
        return md
    }
}
