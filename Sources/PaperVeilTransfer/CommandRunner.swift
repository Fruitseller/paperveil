import Foundation

/// A single command execution. Secrets must never appear in a request.
public struct CommandRequest: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// File whose contents are streamed to the child's stdin. `nil` means an empty stdin.
    public var standardInputFile: URL?

    public init(executable: String, arguments: [String], environment: [String: String] = [:], standardInputFile: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInputFile = standardInputFile
    }
}

/// Result of a finished command: exit status plus captured output.
public struct CommandResult: Sendable, Equatable {
    public var terminationStatus: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputText: String {
        String(data: standardOutput, encoding: .utf8) ?? String(decoding: standardOutput, as: UTF8.self)
    }
    public var standardErrorText: String {
        String(data: standardError, encoding: .utf8) ?? String(decoding: standardError, as: UTF8.self)
    }
    /// Output combined for diagnostic matching. Never contains document content.
    public var combinedText: String { standardOutputText + standardErrorText }
}

/// Executes commands so tests can simulate ssh without networking.
public protocol CommandRunner: Sendable {
    /// Runs the request and waits for the child to exit.
    /// Throws `CancellationError` when the surrounding task is cancelled;
    /// implementations must terminate the child process in that case.
    func run(_ request: CommandRequest) async throws -> CommandResult
}

/// `CommandRunner` backed by Foundation `Process`. Output of both pipes is read
/// concurrently, so large outputs cannot deadlock. On task cancellation the
/// child is terminated (`SIGTERM`) and `CancellationError` is thrown.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        let control = ProcessControlBox()
        return try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: request.executable)
            process.arguments = request.arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var stdinHandle: FileHandle?
            if let inputFile = request.standardInputFile {
                stdinHandle = try FileHandle(forReadingFrom: inputFile)
                process.standardInput = stdinHandle
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            defer { try? stdinHandle?.close() }

            var environment = ProcessInfo.processInfo.environment
            for (key, value) in request.environment { environment[key] = value }
            process.environment = environment

            // terminationHandler instead of waitUntilExit(): the latter can block forever on a
            // background thread without a run loop even after the child has exited.
            let exit = ExitBox()
            process.terminationHandler = { exit.finish($0.terminationStatus) }
            try process.run()
            control.markLaunched(process)

            // Drain both pipes concurrently while the child runs (no 64 KB deadlock).
            let stdoutRead = Task { await Self.readToEnd(FileHandleBox(stdoutPipe.fileHandleForReading)) }
            let stderrRead = Task { await Self.readToEnd(FileHandleBox(stderrPipe.fileHandleForReading)) }
            let status = await exit.value()
            let stdout = await stdoutRead.value
            let stderr = await stderrRead.value
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()

            if Task.isCancelled { throw CancellationError() }
            return CommandResult(terminationStatus: status, standardOutput: stdout, standardError: stderr)
        } onCancel: {
            control.terminateIfRunning()
        }
    }

    // MARK: - helpers (Sendable wrappers for the @Sendable cancellation/wait contexts)

    private static func readToEnd(_ box: FileHandleBox) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? box.handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

}

private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// One-shot exit status that may arrive before or after someone awaits it.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func finish(_ s: Int32) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: s); return }
        status = s
        lock.unlock()
    }

    func value() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let s = status { lock.unlock(); c.resume(returning: s); return }
            waiter = c
            lock.unlock()
        }
    }
}

/// Tracks the child so the cancellation handler can only terminate a running process.
private final class ProcessControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launched = false

    func markLaunched(_ process: Process) {
        lock.lock()
        self.process = process
        launched = true
        lock.unlock()
    }

    func terminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard launched, let process, process.isRunning else { return }
        process.terminate()
    }
}
