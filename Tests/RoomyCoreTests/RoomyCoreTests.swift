import Foundation
import Testing
@testable import RoomyCore

/// A throwaway home folder, so tests never touch real data.
final class FakeHome {
    let url: URL
    let trash: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        trash = url.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 2_000_000, fill: UInt8 = 7, age days: Int? = nil) throws -> URL {
        let f = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: f)
        if let days { try age(relative, days: days) }
        return f
    }

    func age(_ relative: String, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.appendingPathComponent(relative).path)
    }

    func options(_ categories: Set<CategoryID>) -> ScanOptions {
        var o = ScanOptions(home: url)
        o.categories = categories
        o.duplicateMinBytes = 1_000_000
        return o
    }

    var trasher: FolderTrasher { FolderTrasher(folder: trash) }
}

struct FolderTrasher: Trasher {
    let folder: URL
    func trash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(UUID().uuidString))
    }
}

@Suite struct SafetyGuardTests {
    @Test func refusesProtectedAndOutsidePaths() throws {
        let home = try FakeHome()
        for p in ["", "Library", "Library/Caches", "Documents", "Downloads", ".Trash/old.txt"] {
            #expect(throws: RoomyError.self) { try SafetyGuard.validate(home.url.appendingPathComponent(p), home: home.url) }
        }
        #expect(throws: RoomyError.self) { try SafetyGuard.validate(URL(fileURLWithPath: "/usr/lib"), home: home.url) }
        #expect(throws: RoomyError.self) {
            try SafetyGuard.validate(home.url.appendingPathComponent("Library/../Documents"), home: home.url)
        }
    }

    @Test func allowsItemsInsideHome() throws {
        let home = try FakeHome()
        for p in ["Library/Caches/com.example", "code/app/node_modules", "Downloads/setup.dmg"] {
            try SafetyGuard.validate(home.url.appendingPathComponent(p), home: home.url)
        }
    }
}

@Suite struct ScannerTests {
    @Test func findsDeveloperCaches() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/out.o")
        try home.file(".npm/_cacache/content-v2/blob")
        let result = await Scanner.scan(home.options([.devCaches]))
        let paths = result.categories.first?.findings.map(\.url.lastPathComponent) ?? []
        #expect(Set(paths) == ["DerivedData", "_cacache"])
    }

    @Test func findsOnlyStaleProjectDependencies() async throws {
        let home = try FakeHome()
        try home.file("code/old/package.json", bytes: 10, age: 90)
        try home.file("code/old/node_modules/left-pad/index.js")
        try home.age("code/old", days: 90)

        try home.file("code/fresh/package.json", bytes: 10)
        try home.file("code/fresh/node_modules/left-pad/index.js")

        try home.file("code/notaproject/node_modules/x.js", age: 90)  // no package.json

        try home.file("code/py/pyproject.toml", bytes: 10, age: 90)
        try home.file("code/py/.venv/pyvenv.cfg", bytes: 10)
        try home.file("code/py/.venv/lib/site.py")
        try home.age("code/py", days: 90)

        let result = await Scanner.scan(home.options([.staleDependencies]))
        let found = result.categories.first?.findings.map { $0.url.deletingLastPathComponent().lastPathComponent }
        #expect(Set(found ?? []) == ["old", "py"])
    }

    @Test func findsInstallersByAgeAndSkipsThemInLargeFiles() async throws {
        let home = try FakeHome()
        try home.file("Downloads/Tool.dmg")
        try home.file("Downloads/notes.txt")
        // "Added to folder" dates cannot be faked, so a new file is never old by default.
        #expect(await Scanner.scan(home.options([.installers])).categories.isEmpty)

        var o = home.options([.installers, .largeOldFiles])
        o.installerMinDays = 0
        o.largeFileMinBytes = 1_000_000
        o.largeFileUnusedDays = 0
        let byID = Dictionary(uniqueKeysWithValues: await Scanner.scan(o).categories.map { ($0.id, $0.findings) })
        #expect(byID[.installers]?.map(\.url.lastPathComponent) == ["Tool.dmg"])
        #expect(byID[.largeOldFiles]?.map(\.url.lastPathComponent) == ["notes.txt"])
    }
}

@Suite struct CleanerTests {
    @Test func movesCachesToTrashAndReports() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/DerivedData/App/x.o")
        let scan = await Scanner.scan(home.options([.devCaches]))
        let report = await Cleaner.run(scan.categories, home: home.url, trasher: home.trasher)

        #expect(report.failures.isEmpty)
        #expect(report.inTrashBytes > 1_000_000)
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Developer/Xcode/DerivedData").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.trash.path).count == 1)
        #expect(report.markdown().contains("개발 도구 캐시"))
    }

    @Test func refusesFindingOutsideHome() async throws {
        let home = try FakeHome()
        let outside = ScanCategory(id: .appCaches, findings: [Finding(url: URL(fileURLWithPath: "/usr/bin/true"), bytes: 1)])
        let report = await Cleaner.run([outside], home: home.url, trasher: home.trasher)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: "/usr/bin/true"))
    }

    @Test func clonesDuplicatesWithoutRemovingFiles() async throws {
        let home = try FakeHome()
        let a = try home.file("Documents/a.bin", bytes: 3_000_000, fill: 1)
        let b = try home.file("Downloads/b.bin", bytes: 3_000_000, fill: 1)
        try home.file("Desktop/c.bin", bytes: 3_000_000, fill: 2)  // same size, other content
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: b.path)

        let scan = await Scanner.scan(home.options([.duplicates]))
        let dupes = scan.categories.first?.findings ?? []
        #expect(dupes.count == 1)
        #expect(dupes.first?.url.lastPathComponent == "b.bin")

        let report = await Cleaner.run(scan.categories, home: home.url, trasher: home.trasher)
        #expect(report.failures.isEmpty)
        #expect(report.freedNowBytes >= 3_000_000)

        #expect(Duplicates.cloneID(a) == Duplicates.cloneID(b))
        #expect(try Data(contentsOf: b) == Data(repeating: 1, count: 3_000_000))
        let perms = try FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        let rescan = await Scanner.scan(home.options([.duplicates]))
        #expect(rescan.categories.isEmpty, "already-cloned files must not be reported again")
    }

    @Test func skipsDuplicateThatChangedAfterScan() async throws {
        let home = try FakeHome()
        try home.file("Documents/a.bin", fill: 1)
        let b = try home.file("Documents/b.bin", fill: 1)
        let scan = await Scanner.scan(home.options([.duplicates]))
        try Data(repeating: 9, count: 2_000_000).write(to: b)

        let report = await Cleaner.run(scan.categories, home: home.url, trasher: home.trasher)
        #expect(report.failures.count == 1)
        #expect(try Data(contentsOf: b).first == 9)
    }
}

/// Needs ffmpeg to make a sample H.264 clip; skipped where it is missing (e.g. CI).
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
struct VideoTests {
    @Test func convertsH264ToSmallerHEVC() async throws {
        let home = try FakeHome()
        let movies = home.url.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let clip = movies.appendingPathComponent("clip.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "4",
                       "-c:v", "libx264", "-b:v", "25M", "-pix_fmt", "yuv420p", clip.path]
        try p.run()
        p.waitUntilExit()
        #expect(await Videos.isH264(clip))

        var o = home.options([.videos])
        o.videoMinBytes = 1
        let scan = await Scanner.scan(o)
        #expect(scan.categories.first?.findings.count == 1)

        let report = await Cleaner.run(scan.categories, home: home.url, trasher: home.trasher)
        #expect(report.failures.isEmpty, "\(report.failures.map(\.error))")
        #expect(report.inTrashBytes > 0)
        #expect(await !Videos.isH264(clip), "the file at the original path should now be HEVC")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.trash.path).count == 1)
    }
}

/// Regression: an app moved model files into ~/Library/Caches/AIRI and linked them back
/// from its model store. Trashing that "cache" broke the model.
@Suite struct LinkedCacheTests {
    func makeLinkedCache(_ home: FakeHome) throws -> URL {
        let blob = try home.file("Library/Caches/AIRI/gemma/sha256-abc")
        let store = home.url.appendingPathComponent("models/blobs")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("sha256-abc"), withDestinationURL: blob)
        return blob
    }

    @Test func scanFlagsCacheThatIsLinkedFromElsewhere() async throws {
        let home = try FakeHome()
        try makeLinkedCache(home)
        var o = home.options([.appCaches])
        o.appCacheMinBytes = 1
        let finding = try #require(await Scanner.scan(o).categories.first?.findings.first)
        #expect(finding.url.lastPathComponent == "AIRI")
        #expect(finding.caution?.contains("models/blobs/sha256-abc") == true)
    }

    @Test func cleanerRefusesLinkedCacheEvenIfSelected() async throws {
        let home = try FakeHome()
        let blob = try makeLinkedCache(home)
        let cache = home.url.appendingPathComponent("Library/Caches/AIRI")
        let plan = [ScanCategory(id: .appCaches, findings: [Finding(url: cache, bytes: 2_000_000)])]
        let report = await Cleaner.run(plan, home: home.url, trasher: home.trasher)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.error?.contains("링크") == true)
        #expect(FileManager.default.fileExists(atPath: blob.path))
    }

    @Test func linksInsideTheCacheItselfDoNotBlock() async throws {
        let home = try FakeHome()
        let download = try home.file("Library/Caches/Tool/downloads/pkg.tar")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches/Tool/pkg"), withDestinationURL: download)
        var o = home.options([.appCaches])
        o.appCacheMinBytes = 1
        let scan = await Scanner.scan(o)
        #expect(scan.categories.first?.findings.first?.caution == nil)
        let report = await Cleaner.run(scan.categories, home: home.url, trasher: home.trasher)
        #expect(report.failures.isEmpty)
    }

    @Test func largeAppCachesStartFlagged() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Big/data", bytes: 3_000_000)
        try home.file("Library/Caches/Small/data", bytes: 300_000)
        var o = home.options([.appCaches])
        o.appCacheMinBytes = 100_000
        o.appCacheReviewBytes = 1_000_000
        let findings = await Scanner.scan(o).categories.first?.findings ?? []
        let flagged = Dictionary(uniqueKeysWithValues: findings.map { ($0.url.lastPathComponent, $0.caution != nil) })
        #expect(flagged == ["Big": true, "Small": false])
    }
}

@Suite struct ModelFileTests {
    @Test func largeOldFilesNeverIncludeModelWeights() async throws {
        let home = try FakeHome()
        try home.file("Documents/llama-3-8b.Q4_K_M.gguf")
        try home.file("Downloads/sd-xl.safetensors")
        try home.file("Downloads/old-backup.zip")
        var o = home.options([.largeOldFiles])
        o.largeFileMinBytes = 1_000_000
        o.largeFileUnusedDays = 0
        let names = await Scanner.scan(o).categories.first?.findings.map(\.url.lastPathComponent)
        #expect(names == ["old-backup.zip"])
    }

    @Test func appCacheHoldingModelsIsFlagged() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/VoiceApp/models/whisper.safetensors")
        try home.file("Library/Caches/Browser/data")
        var o = home.options([.appCaches])
        o.appCacheMinBytes = 1
        let findings = await Scanner.scan(o).categories.first?.findings ?? []
        let cautions = Dictionary(uniqueKeysWithValues: findings.map { ($0.url.lastPathComponent, $0.caution) })
        #expect(cautions["VoiceApp"]??.contains("AI 모델") == true)
        #expect(cautions["Browser"] == .some(nil))
    }
}
