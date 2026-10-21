import Foundation

enum Shell {
    /// Runs a tool and returns stdout. Throws on a non-zero exit.
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw RoomyError.system("\(URL(fileURLWithPath: executable).lastPathComponent) 실패 (\(p.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// simctl inside the selected Xcode, or nil without Xcode.
    /// Calling `xcrun` without Xcode would pop up an install dialog, so look first.
    static func simctlPath() -> String? {
        guard let dev = try? run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let path = dev + "/usr/bin/simctl"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
