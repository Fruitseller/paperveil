import Foundation
@testable import PaperVeilTransfer
import Testing

@Suite struct ProcessRunnerTests {
    @Test func runsCommandAndCapturesOutput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(CommandRequest(
            executable: "/bin/echo",
            arguments: ["papier", "schleier"],
            environment: ["PV_TEST_VAR": "sichtbar"]
        ))
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) == "papier schleier")

        let envResult = try await runner.run(CommandRequest(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$PV_TEST_VAR\""],
            environment: ["PV_TEST_VAR": "sichtbar"]
        ))
        #expect(envResult.standardOutputText == "sichtbar")
    }

    @Test func feedsStandardInputFile() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("pv-stdin-\(UUID().uuidString)")
        try Data("eingabe-daten".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let runner = ProcessRunner()
        let result = try await runner.run(CommandRequest(
            executable: "/bin/cat",
            arguments: [],
            standardInputFile: input
        ))
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputText == "eingabe-daten")
    }

    @Test func cancellationTerminatesTheChildProcess() async throws {
        let runner = ProcessRunner()
        let started = Date()

        let task = Task {
            try await runner.run(CommandRequest(executable: "/bin/sleep", arguments: ["30"]))
        }
        // Give the child time to launch, then cancel.
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Erwartet: CancellationError")
        } catch is CancellationError {
            // fine
        } catch {
            Issue.record("Falscher Fehler: \(error)")
        }
        // The child must have been terminated, not waited out.
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 20, "Kindprozess wurde bei Abbruch nicht beendet (\(elapsed)s)")
    }
}
