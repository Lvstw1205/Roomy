import Foundation

/// Last line of defence before anything is moved or replaced.
/// Findings only ever point inside the home folder, so anything else is refused.
public enum SafetyGuard {
    static let protectedRelativePaths = [
        "", "Library", "Library/Caches", "Library/Developer", "Library/Developer/Xcode",
        "Library/Developer/CoreSimulator", "Library/Application Support", "Library/Mobile Documents",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
        ".Trash",
    ]

    public static func validate(_ url: URL, home: URL) throws {
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        // Resolve the parent, not the item itself: a symlink is moved as a link.
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let path = parent + "/" + url.lastPathComponent

        guard path.hasPrefix(homePath + "/") else { throw RoomyError.unsafePath(url.path) }
        let relative = String(path.dropFirst(homePath.count + 1))

        if relative == ".Trash" || relative.hasPrefix(".Trash/") { throw RoomyError.unsafePath(url.path) }
        for p in protectedRelativePaths {
            // Refuse the protected folder itself and anything that contains it.
            if relative == p || p.hasPrefix(relative + "/") { throw RoomyError.unsafePath(url.path) }
        }
    }
}
