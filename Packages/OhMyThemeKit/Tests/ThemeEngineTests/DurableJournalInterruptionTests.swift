import Darwin
import Foundation
import Testing

@Suite("Durable journal interruption")
struct DurableJournalInterruptionTests {
    @Test(
        "Forced termination after each durable checkpoint preserves configuration and consistent recovery",
        arguments: CrashScenario.recoverableCases
    )
    func recoverableOperations(scenario: CrashScenario) throws {
        try assertInterruptionRecovery(for: scenario)
    }

    @Test("Forced termination after each Connect checkpoint preserves configuration and consistent recovery")
    func connectInterruption() throws {
        try assertInterruptionRecovery(for: .connect)
    }

    private func assertInterruptionRecovery(for scenario: CrashScenario) throws {
        let checkpoints = try discoverCheckpoints(for: scenario)
        #expect(!checkpoints.isEmpty)

        for (ordinal, checkpoint) in checkpoints.enumerated() {
            let verification = try interruptAndVerify(
                scenario: scenario,
                checkpointOrdinal: ordinal
            )
            #expect(
                verification.failures.isEmpty,
                "\(scenario.rawValue) after #\(ordinal) \(checkpoint): \(verification.failures.joined(separator: "; "))"
            )
        }
    }

    private func discoverCheckpoints(for scenario: CrashScenario) throws -> [String] {
        let root = temporaryRoot(suffix: "discover-\(scenario.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runHelper(arguments: ["discover", scenario.rawValue, root.path])
        #expect(result.status == 0, "helper stderr: \(result.stderr)")
        return try JSONDecoder().decode(Discovery.self, from: Data(result.stdout.utf8)).checkpoints
    }

    private func interruptAndVerify(
        scenario: CrashScenario,
        checkpointOrdinal: Int
    ) throws -> Verification {
        let root = temporaryRoot(suffix: "interrupt-\(scenario.rawValue)-\(checkpointOrdinal)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let markerURL = root.appendingPathComponent("checkpoint-marker.json")
        let process = Process()
        process.executableURL = try helperExecutableURL()
        process.arguments = [
            "run",
            scenario.rawValue,
            root.path,
            String(checkpointOrdinal),
        ]
        let standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: markerURL.path),
            process.isRunning,
            Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if !FileManager.default.fileExists(atPath: markerURL.path) {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            let stderr =
                String(
                    data: standardError.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            Issue.record("helper did not reach checkpoint #\(checkpointOrdinal): \(stderr)")
            throw HarnessError.checkpointNotReached
        }

        #expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        let verificationResult = try runHelper(arguments: ["verify", scenario.rawValue, root.path])
        #expect(verificationResult.status == 0, "helper stderr: \(verificationResult.stderr)")
        return try JSONDecoder().decode(
            Verification.self,
            from: Data(verificationResult.stdout.utf8)
        )
    }

    private func runHelper(arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try helperExecutableURL()
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func helperExecutableURL() throws -> URL {
        let packageBuildCandidate = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/debug/DurabilityCrashHarness")
        if FileManager.default.isExecutableFile(atPath: packageBuildCandidate.path) {
            return packageBuildCandidate
        }

        var directory = try #require(Bundle.main.executableURL).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("DurabilityCrashHarness")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw HarnessError.helperNotFound
    }

    private func temporaryRoot(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-durability-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}

enum CrashScenario: String, CaseIterable, CustomTestStringConvertible {
    case connect
    case apply
    case undo
    case restore
    case disconnect

    static let recoverableCases: [CrashScenario] = [.apply, .undo, .restore, .disconnect]

    var testDescription: String { rawValue }
}

private struct Discovery: Decodable {
    let checkpoints: [String]
}

private struct Verification: Decodable {
    let failures: [String]
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum HarnessError: Error {
    case helperNotFound
    case checkpointNotReached
}
