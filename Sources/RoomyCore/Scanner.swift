import Foundation

public struct ScanOptions: Sendable {
    public var home: URL
    public var categories: Set<CategoryID> = Set(CategoryID.allCases)
    public var now = Date()
    public var staleProjectDays = 30
    public var appCacheMinBytes: Int64 = 50_000_000
    /// App caches this big may hold real data (models, media), so they start unselected.
    public var appCacheReviewBytes: Int64 = 1_000_000_000
    /// Mark items that something else still reaches through a symlink.
    public var checkLinks = true
    public var installerMinDays = 7
    public var largeFileMinBytes: Int64 = 1_000_000_000
    public var largeFileUnusedDays = 90
    public var duplicateMinBytes: Int64 = 10_000_000
    public var videoMinBytes: Int64 = 300_000_000

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    func urls(_ relatives: [String]) -> [URL] { relatives.map(url) }
}

public enum Scanner {
    /// Scans every requested category in parallel. Read-only: nothing is changed on disk.
    public static func scan(
        _ options: ScanOptions,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ScanResult {
        let start = Date()
        // The link walk takes a few seconds, so it runs alongside the category scans.
        let wantsLinks = options.checkLinks && options.categories.contains { $0.action == .moveToTrash }
        let links: Task<LinkIndex, Never>? = wantsLinks
            ? Task.detached { LinkIndex.build(home: options.home) } : nil

        var categories = await withTaskGroup(of: ScanCategory.self) { group in
            for id in options.categories {
                group.addTask {
                    progress("\(id.title) 확인 중…")
                    let findings = await Rules.findings(for: id, options)
                    progress("\(id.title) 완료")
                    return ScanCategory(id: id, findings: findings)
                }
            }
            var all: [ScanCategory] = []
            for await c in group where !c.findings.isEmpty { all.append(c) }
            return all
        }
        if let links {
            progress("링크 확인 중…")
            let index = await links.value
            categories = categories.map { c in
                guard c.id.action == .moveToTrash else { return c }
                return ScanCategory(id: c.id, findings: c.findings.map { f in
                    guard let l = index.incomingLink(into: f.url) else { return f }
                    var marked = f
                    marked.caution = "다른 곳에서 링크로 쓰는 중이에요: \(l.link)"
                    return marked
                })
            }
        }
        let order = CategoryID.allCases
        return ScanResult(
            categories: categories.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! },
            disk: DiskStatus.current(home: options.home),
            duration: Date().timeIntervalSince(start)
        )
    }
}

enum Rules {
    static func findings(for id: CategoryID, _ o: ScanOptions) async -> [Finding] {
        switch id {
        case .devCaches: devCaches(o)
        case .appCaches: appCaches(o)
        case .staleDependencies: staleDependencies(o)
        case .simulators: unavailableSimulators()
        case .installers: installers(o)
        case .largeOldFiles: largeOldFiles(o)
        case .duplicates: Duplicates.find(o)
        case .videos: await Videos.find(o)
        }
    }

    // MARK: Developer caches

    /// Caches that their tools rebuild on demand. Paths are relative to home.
    static let devCachePaths: [(path: String, name: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode 빌드 중간 파일"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "iOS 기기 디버그 심볼"),
        ("Library/Developer/Xcode/watchOS DeviceSupport", "watchOS 기기 디버그 심볼"),
        ("Library/Developer/Xcode/tvOS DeviceSupport", "tvOS 기기 디버그 심볼"),
        ("Library/Developer/Xcode/xrOS DeviceSupport", "visionOS 기기 디버그 심볼"),
        ("Library/Developer/CoreSimulator/Caches", "시뮬레이터 캐시"),
        ("Library/Caches/com.apple.dt.Xcode", "Xcode 캐시"),
        (".npm/_cacache", "npm 캐시"),
        ("Library/Caches/Yarn", "Yarn 캐시"),
        ("Library/Caches/pip", "pip 캐시"),
        ("Library/Caches/pypoetry", "Poetry 캐시"),
        (".cache/uv", "uv 캐시"),
        ("Library/Caches/Homebrew", "Homebrew 다운로드 캐시"),
        ("Library/Caches/CocoaPods", "CocoaPods 캐시"),
        ("Library/Caches/go-build", "Go 빌드 캐시"),
        (".gradle/caches", "Gradle 캐시"),
        (".cargo/registry/cache", "Cargo 다운로드 캐시"),
    ]

    static func devCaches(_ o: ScanOptions) -> [Finding] {
        devCachePaths.compactMap { item in
            let url = o.url(item.path)
            let size = FileSystem.allocatedSize(url)
            return size > 1_000_000 ? Finding(url: url, bytes: size, note: item.name) : nil
        }
    }

    // MARK: App caches

    static func appCaches(_ o: ScanOptions) -> [Finding] {
        let caches = o.url("Library/Caches")
        let covered = Set(devCachePaths.map(\.path).filter { $0.hasPrefix("Library/Caches/") }
            .map { String($0.dropFirst("Library/Caches/".count)) })
        let ownID = Bundle.main.bundleIdentifier ?? "app.roomy.Roomy"
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: caches, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { url in
            let name = url.lastPathComponent
            guard !covered.contains(name), name != ownID else { return nil }
            let size = FileSystem.allocatedSize(url)
            guard size >= o.appCacheMinBytes else { return nil }
            let caution = size >= o.appCacheReviewBytes
                ? "\(o.appCacheReviewBytes.formattedBytes)가 넘는 캐시예요. 앱이 실제 데이터를 넣어 뒀을 수 있어요." : nil
            return Finding(url: url, bytes: size, note: name, caution: caution)
        }
    }

    // MARK: Stale project dependencies

    struct ArtifactRule {
        let folder: String
        /// A file next to the folder that proves it belongs to a project.
        let siblingMarker: String?
        /// A file inside the folder that proves what it is.
        let insideMarker: String?
        let reinstall: String
    }

    static let artifactRules = [
        ArtifactRule(folder: "node_modules", siblingMarker: "package.json", insideMarker: nil, reinstall: "npm install"),
        ArtifactRule(folder: ".venv", siblingMarker: nil, insideMarker: "pyvenv.cfg", reinstall: "가상환경 다시 만들기"),
        ArtifactRule(folder: "venv", siblingMarker: nil, insideMarker: "pyvenv.cfg", reinstall: "가상환경 다시 만들기"),
        ArtifactRule(folder: "target", siblingMarker: "Cargo.toml", insideMarker: nil, reinstall: "cargo build"),
        ArtifactRule(folder: ".build", siblingMarker: "Package.swift", insideMarker: nil, reinstall: "swift build"),
        ArtifactRule(folder: "Pods", siblingMarker: "Podfile", insideMarker: nil, reinstall: "pod install"),
    ]

    /// Files whose modification time says someone worked on the project.
    static let activityFiles = [
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
        "Cargo.toml", "Cargo.lock", "Package.swift", "Package.resolved",
        "pyproject.toml", "requirements.txt", "uv.lock", "poetry.lock",
        "Podfile", "Podfile.lock", ".git/index",
    ]

    static func lastActivity(of project: URL) -> Date? {
        (activityFiles.map { project.appendingPathComponent($0) } + [project])
            .compactMap(FileSystem.modificationDate)
            .max()
    }

    static func staleDependencies(_ o: ScanOptions) -> [Finding] {
        let skippedTopLevel: Set = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let maxDepth = 8
        guard let tops = try? FileManager.default.contentsOfDirectory(
            at: o.home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Finding] = []
        for top in tops where !skippedTopLevel.contains(top.lastPathComponent) && FileSystem.isDirectory(top) {
            guard let e = FileManager.default.enumerator(
                at: top, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = e.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if e.level > maxDepth { e.skipDescendants(); continue }

                let name = url.lastPathComponent
                let project = url.deletingLastPathComponent()
                if let rule = artifactRules.first(where: { $0.folder == name }),
                   rule.siblingMarker.map({ FileSystem.exists(project.appendingPathComponent($0)) }) ?? true,
                   rule.insideMarker.map({ FileSystem.exists(url.appendingPathComponent($0)) }) ?? true {
                    e.skipDescendants()
                    let idle = FileSystem.days(since: lastActivity(of: project), now: o.now)
                    guard idle >= o.staleProjectDays else { continue }
                    let size = FileSystem.allocatedSize(url)
                    guard size > 1_000_000 else { continue }
                    found.append(Finding(
                        url: url, bytes: size,
                        note: "\(project.lastPathComponent) · \(idle)일 동안 작업 없음 · 복구: \(rule.reinstall)"
                    ))
                } else if name.hasPrefix(".") || name == "node_modules" {
                    e.skipDescendants()
                }
            }
        }
        return found
    }

    // MARK: Unavailable simulators

    static func unavailableSimulators() -> [Finding] {
        guard let simctl = Shell.simctlPath(),
              let out = try? Shell.run(simctl, ["list", "devices", "unavailable", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { d in
            guard let udid = d["udid"] as? String, let dataPath = d["dataPath"] as? String else { return nil }
            let url = URL(fileURLWithPath: dataPath).deletingLastPathComponent()
            return Finding(url: url, bytes: FileSystem.allocatedSize(url),
                           note: (d["name"] as? String) ?? udid, token: udid)
        }
    }

    // MARK: Installers and large old files

    static let installerExtensions: Set = ["dmg", "pkg", "mpkg", "iso", "xip"]

    static func installers(_ o: ScanOptions) -> [Finding] {
        var found: [Finding] = []
        FileSystem.regularFiles(
            under: o.urls(["Downloads", "Desktop"]),
            keys: [.totalFileAllocatedSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        ) { url, v in
            guard installerExtensions.contains(url.pathExtension.lowercased()) else { return }
            let newest = [v.contentModificationDate, v.addedToDirectoryDate].compactMap { $0 }.max()
            let age = FileSystem.days(since: newest, now: o.now)
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            guard age >= o.installerMinDays, size > 1_000_000 else { return }
            found.append(Finding(url: url, bytes: size, note: "\(age)일 전 받은 파일"))
        }
        return found
    }

    static func largeOldFiles(_ o: ScanOptions) -> [Finding] {
        var found: [Finding] = []
        FileSystem.regularFiles(
            under: o.urls(["Downloads", "Desktop", "Documents", "Movies"]),
            keys: [.totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        ) { url, v in
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            guard size >= o.largeFileMinBytes,
                  !installerExtensions.contains(url.pathExtension.lowercased()) else { return }
            let lastUsed = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
            let idle = FileSystem.days(since: lastUsed, now: o.now)
            guard idle >= o.largeFileUnusedDays else { return }
            found.append(Finding(url: url, bytes: size, note: "\(idle)일 동안 열지 않음"))
        }
        return found
    }
}
