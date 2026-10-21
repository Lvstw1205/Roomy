import Foundation

/// How careful the user should be before cleaning a category.
public enum Safety: String, Sendable, Codable {
    /// Regenerable data, or an operation that never removes content.
    case safe
    /// User data. Look at the list before cleaning.
    case review
}

/// What the cleaner does with each finding of a category.
public enum CleanupAction: String, Sendable, Codable {
    case moveToTrash
    case deleteSimulator
    case cloneDuplicate
    case convertToHEVC
}

/// Scan categories, in the order they are shown and cleaned.
/// Trash-based categories run before duplicates and videos, so a file that was
/// already moved to the Trash is skipped by the later steps.
public enum CategoryID: String, Sendable, Codable, CaseIterable {
    case devCaches
    case appCaches
    case staleDependencies
    case simulators
    case installers
    case largeOldFiles
    case duplicates
    case videos

    public var title: String {
        switch self {
        case .devCaches: "개발 도구 캐시"
        case .appCaches: "앱 캐시"
        case .staleDependencies: "오래된 프로젝트 의존성"
        case .simulators: "사용할 수 없는 시뮬레이터"
        case .installers: "오래된 설치 파일"
        case .largeOldFiles: "오래 안 연 큰 파일"
        case .duplicates: "중복 파일 합치기"
        case .videos: "영상 압축 (H.264 → HEVC)"
        }
    }

    public var explanation: String {
        switch self {
        case .devCaches:
            "Xcode 빌드 파일, npm·pip·Homebrew 캐시 등이에요. 필요하면 도구가 다시 만들어요."
        case .appCaches:
            "앱이 임시로 저장한 파일이에요. 앱이 다시 만들어요. 정리 전에 앱을 종료하면 좋아요."
        case .staleDependencies:
            "한동안 손대지 않은 프로젝트의 node_modules, .venv, target 등이에요. 설치 명령으로 다시 받을 수 있어요."
        case .simulators:
            "런타임이 지워져서 더 이상 실행할 수 없는 시뮬레이터예요."
        case .installers:
            "다운로드 폴더 등에 남은 .dmg, .pkg 같은 설치 파일이에요."
        case .largeOldFiles:
            "크고 오랫동안 열지 않은 파일이에요. 목록을 꼭 확인하세요."
        case .duplicates:
            "내용이 같은 파일을 APFS 복제본으로 바꿔 공간을 공유해요. 파일은 하나도 지우지 않아요."
        case .videos:
            "화질은 거의 그대로, 용량은 보통 40% 정도 줄어요. 오래 걸리고, 원본은 휴지통으로 가요."
        }
    }

    public var symbol: String {
        switch self {
        case .devCaches: "hammer"
        case .appCaches: "square.stack.3d.up"
        case .staleDependencies: "shippingbox"
        case .simulators: "iphone.slash"
        case .installers: "opticaldiscdrive"
        case .largeOldFiles: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .videos: "film"
        }
    }

    public var safety: Safety {
        switch self {
        case .devCaches, .appCaches, .staleDependencies, .simulators, .duplicates: .safe
        case .installers, .largeOldFiles, .videos: .review
        }
    }

    public var action: CleanupAction {
        switch self {
        case .simulators: .deleteSimulator
        case .duplicates: .cloneDuplicate
        case .videos: .convertToHEVC
        default: .moveToTrash
        }
    }

    /// Safe categories are preselected; the rest wait for the user.
    public var enabledByDefault: Bool { safety == .safe }
}

/// One thing the scanner found that can be cleaned.
public struct Finding: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let url: URL
    /// Estimated bytes this finding frees.
    public let bytes: Int64
    public let note: String
    /// Duplicates: the file whose data this one will share.
    public let original: URL?
    /// Simulators: the device UDID.
    public let token: String?
    /// Why this item should be looked at before cleaning. Items with a caution
    /// start unselected even in a safe category.
    public var caution: String?

    public init(url: URL, bytes: Int64, note: String = "", original: URL? = nil, token: String? = nil,
                caution: String? = nil) {
        self.id = UUID()
        self.url = url
        self.bytes = bytes
        self.note = note
        self.original = original
        self.token = token
        self.caution = caution
    }
}

public struct ScanCategory: Identifiable, Sendable {
    public let id: CategoryID
    public var findings: [Finding]

    public init(id: CategoryID, findings: [Finding]) {
        self.id = id
        self.findings = findings.sorted { $0.bytes > $1.bytes }
    }

    public var totalBytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
}

public struct ScanResult: Sendable {
    public let categories: [ScanCategory]
    public let disk: DiskStatus
    public let duration: TimeInterval

    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }
}

public enum RoomyError: LocalizedError {
    case unsafePath(String)
    case missing(String)
    case linked(String)
    case changedSinceScan
    case notWorthIt
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let p): "보호된 위치라서 건너뛰었어요: \(p)"
        case .missing(let p): "파일이 이미 없어요: \(p)"
        case .linked(let link): "다른 곳에서 링크로 쓰는 중이라 건너뛰었어요: \(link)"
        case .changedSinceScan: "스캔 후에 파일이 바뀌어서 건너뛰었어요."
        case .notWorthIt: "압축해도 10% 이상 줄지 않아서 원본을 그대로 뒀어요."
        case .system(let m): m
        }
    }
}

extension Int64 {
    public var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
