import Darwin
import Foundation

/// Every symlink under the home folder, plus links on external drives that the
/// home folder links to, with the path each one points at.
///
/// Used to keep Roomy from trashing a folder that something else still reads
/// through a link — for example model files an app moved into ~/Library/Caches
/// and linked back from an external drive.
public struct LinkIndex: Sendable {
    public struct Link: Sendable {
        public let link: String
        public let target: String
    }

    public let links: [Link]

    public init(links: [Link]) {
        self.links = links
    }

    /// Builds the index with `find`, which walks a typical home folder in a few seconds.
    public static func build(home: URL) -> LinkIndex {
        var links = symlinks(under: home.path, maxDepth: nil)
        // Follow links that leave home for an external drive, e.g. ~/.ollama/models → /Volumes/SSD/...
        let externalRoots = Set(links.map(\.target).filter { target in
            target.hasPrefix("/Volumes/") && FileSystem.isDirectory(URL(fileURLWithPath: target))
        })
        for root in externalRoots.sorted().prefix(50) {
            links += symlinks(under: root, maxDepth: 6)
        }
        return LinkIndex(links: links)
    }

    /// A link outside `url` that points at `url` or something inside it.
    public func incomingLink(into url: URL) -> Link? {
        let candidates = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
        return links.first { l in
            candidates.contains { base in
                let inside = l.target == base || l.target.hasPrefix(base + "/")
                let fromOutside = l.link != base && !l.link.hasPrefix(base + "/")
                return inside && fromOutside
            }
        }
    }

    static func symlinks(under root: String, maxDepth: Int?) -> [Link] {
        var args = [root]
        if let maxDepth { args += ["-maxdepth", String(maxDepth)] }
        args += ["-type", "l", "-print0"]
        guard let out = try? Shell.run("/usr/bin/find", args, allowFailure: true) else { return [] }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        return out.split(separator: "\0").compactMap { raw in
            let link = String(raw)
            // readlink(2) directly: FileManager is several times slower over tens of thousands of links.
            let n = readlink(link, &buffer, buffer.count - 1)
            guard n > 0 else { return nil }
            let dest = String(decoding: buffer[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let joined = dest.hasPrefix("/") ? dest : (link as NSString).deletingLastPathComponent + "/" + dest
            let target = joined.contains("/.") || joined.contains("//") ? (joined as NSString).standardizingPath : joined
            return Link(link: link, target: target)
        }
    }
}
