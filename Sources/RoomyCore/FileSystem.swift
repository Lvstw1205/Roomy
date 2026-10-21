import Darwin
import Foundation

/// Small file system helpers. Everything here is synchronous on purpose:
/// directory enumerators cannot be iterated from async contexts.
public enum FileSystem {
    static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Bytes actually allocated on disk for a file or a whole directory tree.
    public static func allocatedSize(_ url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: sizeKeys), v.isSymbolicLink != true else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        while let file = e.nextObject() as? URL {
            guard let r = try? file.resourceValues(forKeys: sizeKeys),
                  r.isDirectory != true, r.isSymbolicLink != true else { continue }
            total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Regular, non-hidden files under `roots`, skipping app bundles and photo libraries.
    static func regularFiles(
        under roots: [URL],
        keys: [URLResourceKey],
        _ body: (URL, URLResourceValues) -> Void
    ) {
        let keySet = Set(keys + [.isRegularFileKey, .isSymbolicLinkKey])
        for root in roots where isDirectory(root) {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keySet),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            while let url = e.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: keySet),
                      v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                body(url, v)
            }
        }
    }

    static func days(since date: Date?, now: Date) -> Int {
        guard let date else { return Int.max }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}

/// Disk capacity of the volume that holds the home folder.
public struct DiskStatus: Sendable, Codable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    /// nil when the Trash cannot be read (it needs Full Disk Access on recent macOS).
    public let trashBytes: Int64?

    public var usedBytes: Int64 { totalBytes - availableBytes }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskStatus {
        let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let trash = home.appendingPathComponent(".Trash")
        let trashBytes: Int64? = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) == nil
            ? nil : FileSystem.allocatedSize(trash)
        return DiskStatus(
            totalBytes: Int64(v?.volumeTotalCapacity ?? 0),
            availableBytes: v?.volumeAvailableCapacityForImportantUsage ?? 0,
            trashBytes: trashBytes
        )
    }
}
