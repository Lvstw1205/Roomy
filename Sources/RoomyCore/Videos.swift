import AVFoundation
import Foundation

/// Finds large H.264 videos and re-encodes them to HEVC with the Mac's hardware encoder.
public enum Videos {
    static let roots = ["Movies", "Downloads", "Desktop", "Documents"]
    static let extensions: Set = ["mp4", "mov", "m4v"]
    /// HEVC at the same quality is typically 40–50% smaller than H.264.
    static let expectedSaving = 0.4

    static func find(_ o: ScanOptions) async -> [Finding] {
        var candidates: [(URL, Int64)] = []
        FileSystem.regularFiles(under: o.urls(roots), keys: [.totalFileAllocatedSizeKey]) { url, v in
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            if size >= o.videoMinBytes, extensions.contains(url.pathExtension.lowercased()) {
                candidates.append((url, size))
            }
        }
        var found: [Finding] = []
        for (url, size) in candidates where await isH264(url) {
            found.append(Finding(url: url, bytes: Int64(Double(size) * expectedSaving),
                                 note: "\(size.formattedBytes) · H.264"))
        }
        return found
    }

    static func isH264(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return false }
        return CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264
    }

    /// Converts in place: the HEVC file takes the original's name and the original
    /// goes to the Trash. Returns the bytes saved. Keeps the original when the
    /// result is not at least 10% smaller.
    public static func convertToHEVC(_ source: URL, trasher: Trasher) async throws -> Int64 {
        guard FileSystem.exists(source) else { throw RoomyError.missing(source.path) }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
        else { throw RoomyError.system("이 영상은 HEVC로 내보낼 수 없어요.") }

        let isMOV = source.pathExtension.lowercased() == "mov"
        let temp = source.deletingLastPathComponent()
            .appendingPathComponent(".roomy-\(UUID().uuidString).\(isMOV ? "mov" : "mp4")")
        do {
            try await session.export(to: temp, as: isMOV ? .mov : .mp4)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        let before = FileSystem.allocatedSize(source)
        let after = FileSystem.allocatedSize(temp)
        guard Double(after) < Double(before) * 0.9 else {
            try? FileManager.default.removeItem(at: temp)
            throw RoomyError.notWorthIt
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: source.path) {
            let dates = attrs.filter { $0.key == .creationDate || $0.key == .modificationDate }
            try? FileManager.default.setAttributes(dates, ofItemAtPath: temp.path)
        }
        try trasher.trash(source)
        try FileManager.default.moveItem(at: temp, to: source)
        return before - after
    }
}
