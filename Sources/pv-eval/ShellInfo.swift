import Foundation

/// Runs a subprocess and returns its stdout (trimmed), or nil on failure.
/// Used only for environment info in report headers (git commit, swift version).
func shellOutput(_ launchPath: String, _ arguments: [String], workingDirectory: String? = nil) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (string?.isEmpty == true) ? nil : string
}

struct EnvironmentInfo: Sendable {
    var date: String
    var gitCommit: String
    var macOS: String
    var swiftVersion: String
}

func collectEnvironmentInfo() -> EnvironmentInfo {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let date = formatter.string(from: Date())

    let cwd = FileManager.default.currentDirectoryPath
    let gitCommit = shellOutput("/usr/bin/git", ["rev-parse", "HEAD"], workingDirectory: cwd)
        ?? "nicht verfügbar (kein Git-Repository)"
    let macOS = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    let firstSwiftLine = shellOutput("/usr/bin/xcrun", ["swift", "--version"], workingDirectory: cwd)
        .map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
    let swiftVersion = firstSwiftLine ?? "nicht verfügbar"

    return EnvironmentInfo(date: date, gitCommit: gitCommit, macOS: macOS, swiftVersion: swiftVersion)
}
