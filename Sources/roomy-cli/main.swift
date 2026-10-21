import Foundation
import RoomyCore

// roomy-cli scan [--only devCaches,appCaches,...]
// Read-only: prints what Roomy would clean. Cleaning is done in the app.

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "scan" else {
    print("""
    usage: roomy-cli scan [--only <categories>]

    categories: \(CategoryID.allCases.map(\.rawValue).joined(separator: ", "))
    """)
    exit(args.isEmpty ? 0 : 1)
}

var options = ScanOptions()
if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
    let ids = args[i + 1].split(separator: ",").compactMap { CategoryID(rawValue: String($0)) }
    guard !ids.isEmpty else { print("unknown category: \(args[i + 1])"); exit(1) }
    options.categories = Set(ids)
}

let result = await Scanner.scan(options)
let home = options.home.path
print("남은 공간 \(result.disk.availableBytes.formattedBytes) / \(result.disk.totalBytes.formattedBytes)")
print("정리 가능 \(result.totalBytes.formattedBytes) · \(String(format: "%.1f", result.duration))초\n")
for c in result.categories {
    let mark = c.id.safety == .safe ? "안전" : "확인 필요"
    print("■ \(c.id.title) [\(mark)] \(c.totalBytes.formattedBytes) · \(c.findings.count)개")
    for f in c.findings.prefix(5) {
        let path = f.url.path.hasPrefix(home) ? "~" + f.url.path.dropFirst(home.count) : f.url.path
        print("    \(f.bytes.formattedBytes.padding(toLength: 10, withPad: " ", startingAt: 0)) \(path)")
    }
    if c.findings.count > 5 { print("    … 외 \(c.findings.count - 5)개") }
}
