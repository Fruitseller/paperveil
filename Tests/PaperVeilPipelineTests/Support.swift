import Foundation
import PaperVeilCore
import PaperVeilTransfer

enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Fixtures/synthetic")
    static let receiver = root.appendingPathComponent("receiver/paperveil-receive")
}

func tempDir(_ prefix: String = "pv") throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@discardableResult
func sh(_ path: String, _ args: [String], stdin: URL? = nil, env: [String: String] = [:]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let out = Pipe()
    p.standardOutput = out; p.standardError = out
    if let stdin { p.standardInput = try FileHandle(forReadingFrom: stdin) }
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A real OpenSSH server on 127.0.0.1 (unprivileged, current user) whose only
/// authorized key is bound to `receiver/paperveil-receive` as a forced command.
/// This is the "ausdrücklich autorisiertes synthetisches Testziel" of the acceptance run.
final class LocalSSHServer: @unchecked Sendable {
    let dir: URL
    let inbox: URL
    let clientKey: URL
    let port: Int
    private var process: Process?

    static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    init() throws {
        dir = try tempDir("pv-sshd")
        inbox = dir.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        clientKey = dir.appendingPathComponent("client")
        port = Int.random(in: 30000...45000)
        try sh("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", clientKey.path])
        let pub = try String(contentsOf: dir.appendingPathComponent("client.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = "command=\"/bin/sh \(Repo.receiver.path) \(inbox.path)\",restrict \(pub)\n"
        try auth.write(to: dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
    }

    /// Starts sshd with a freshly generated host key (`name` lets a test swap identities).
    func start(hostKeyName: String = "hostkey") throws {
        stop()
        let hostKey = dir.appendingPathComponent(hostKeyName)
        if !FileManager.default.fileExists(atPath: hostKey.path) {
            try sh("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        }
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(dir.appendingPathComponent("authorized_keys").path)
        PidFile \(dir.appendingPathComponent("sshd.pid").path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowTcpForwarding no
        Subsystem sftp internal-sftp
        """
        let cfg = dir.appendingPathComponent("sshd_config")
        try config.write(to: cfg, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-e", "-f", cfg.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        process = p
        // Wait until the port accepts connections.
        for _ in 0..<50 {
            if (try? sh("/usr/bin/nc", ["-z", "127.0.0.1", "\(port)"]).0) == 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    var config: TransferConfiguration {
        TransferConfiguration(host: "127.0.0.1", port: port, user: NSUserName(), identityFilePath: clientKey.path)
    }

    /// Raw ssh with the given known_hosts file (for negative tests).
    func ssh(knownHosts: URL, _ remote: [String], stdin: URL? = nil) throws -> (Int32, String) {
        try sh("/usr/bin/ssh", TransferService.sshArguments(config: config, knownHostsFile: knownHosts, name: "x", sha256: "x", byteCount: 0)
            .prefix { $0 != "--" } + ["--"] + remote, stdin: stdin)
    }

    deinit { stop() }
}
