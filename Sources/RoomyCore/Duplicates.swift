import CryptoKit
import Darwin
import Foundation

/// Finds identical files and turns copies into APFS clones of one original.
/// A clone shares the original's blocks until either file is edited, so no
/// file disappears and nothing goes to the Trash.
public enum Duplicates {
    static let roots = ["Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music"]

    struct Candidate {
        let url: URL
        let size: Int64
        let allocated: Int64
        let device: dev_t
        let inode: ino_t
    }

    static func find(_ o: ScanOptions) -> [Finding] {
        var bySize: [String: [Candidate]] = [:]
        FileSystem.regularFiles(under: o.urls(roots), keys: [.fileSizeKey, .totalFileAllocatedSizeKey]) { url, v in
            let size = Int64(v.fileSize ?? 0)
            guard size >= o.duplicateMinBytes else { return }
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return }
            let c = Candidate(url: url, size: size, allocated: Int64(v.totalFileAllocatedSize ?? 0),
                              device: st.st_dev, inode: st.st_ino)
            // Clones only work within one volume.
            bySize["\(st.st_dev)-\(size)", default: []].append(c)
        }

        var found: [Finding] = []
        for group in bySize.values where group.count > 1 {
            // Cheap pass on the first megabyte, then a full hash for what still matches.
            let byHead = Dictionary(grouping: group) { sha256($0.url, limit: 1 << 20) ?? UUID().uuidString }
            for heads in byHead.values where heads.count > 1 {
                let byFull = Dictionary(grouping: heads) { sha256($0.url) ?? UUID().uuidString }
                for same in byFull.values where same.count > 1 {
                    found += findings(for: same)
                }
            }
        }
        return found
    }

    static func findings(for identical: [Candidate]) -> [Finding] {
        let sorted = identical.sorted { $0.url.path < $1.url.path }
        let keeper = sorted[0]
        let keeperClone = cloneID(keeper.url)
        return sorted.dropFirst().compactMap { c in
            if c.inode == keeper.inode { return nil }  // hard link to the same file
            if let id = keeperClone, id == cloneID(c.url) { return nil }  // already shares data
            return Finding(url: c.url, bytes: c.allocated,
                           note: "같은 내용: \(keeper.url.lastPathComponent)", original: keeper.url)
        }
    }

    public static func sha256(_ url: URL, limit: Int = .max) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var remaining = limit
        while remaining > 0, let chunk = try? h.read(upToCount: min(4 << 20, remaining)), !chunk.isEmpty {
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The identifier of a file's data stream. Clones of one file report the same ID.
    public static func cloneID(_ url: URL) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 32)
        let r = getattrlist(url.path, &list, &buffer, buffer.count,
                            UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard r == 0 else { return nil }
        // Layout: u_int32_t length, then the u_int64_t clone ID.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    /// Replaces `duplicate` with a clone of `original`, keeping the duplicate's
    /// own name, permissions, dates and extended attributes.
    public static func replaceWithClone(_ duplicate: URL, original: URL) throws {
        guard FileSystem.exists(duplicate), FileSystem.exists(original) else {
            throw RoomyError.missing(duplicate.path)
        }
        guard let a = sha256(duplicate), a == sha256(original) else { throw RoomyError.changedSinceScan }

        let temp = duplicate.deletingLastPathComponent().appendingPathComponent(".roomy-\(UUID().uuidString)")
        guard clonefile(original.path, temp.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw RoomyError.system("복제 실패: \(String(cString: strerror(errno)))")
        }
        do {
            stripExtendedAttributes(temp)
            guard copyfile(duplicate.path, temp.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw RoomyError.system("메타데이터 복사 실패: \(String(cString: strerror(errno)))")
            }
            guard rename(temp.path, duplicate.path) == 0 else {
                throw RoomyError.system("교체 실패: \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temp.path)  // our own temporary clone, never user data
            throw error
        }
    }

    static func stripExtendedAttributes(_ url: URL) {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        listxattr(url.path, &names, size, XATTR_NOFOLLOW)
        names.split(separator: 0).forEach { name in
            removexattr(url.path, String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self), XATTR_NOFOLLOW)
        }
    }
}
