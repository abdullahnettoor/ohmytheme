import Foundation
import Testing

@testable import PlatformClients

@Suite("Bounded process runner")
struct ProcessRunnerTests {
    @Test("The runner drains child output while retaining only the configured limit")
    func boundsCapturedOutputWithoutBlockingChild() async throws {
        let runner = ProcessRunner(timeout: 2, maximumOutputBytes: 1_024)
        let output = String(repeating: "x", count: 100_000)

        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", output]
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.utf8.count == 1_024)
    }

    @Test("The runner terminates a process that exceeds its timeout")
    func enforcesTimeout() async {
        let runner = ProcessRunner(timeout: 0.05)

        await #expect(throws: ProcessRunnerError.timedOut(0.05)) {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"]
            )
        }
    }
}
