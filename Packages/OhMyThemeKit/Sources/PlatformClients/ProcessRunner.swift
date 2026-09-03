import Darwin
import Foundation

public struct ProcessCall: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        terminationStatus: Int32,
        standardOutput: String,
        standardError: String
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case executableMustBeAbsolute(URL)
    case timedOut(TimeInterval)
}

/// Runs an absolute executable directly through Foundation `Process`. It never
/// invokes a shell and drains both pipes while the process runs, retaining only
/// bounded output for diagnostics.
public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 30, maximumOutputBytes: Int = 65_536) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        guard executableURL.path.hasPrefix("/") else {
            throw ProcessRunnerError.executableMustBeAbsolute(executableURL)
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput

        return try await withTaskCancellationHandler {
            try process.run()
            async let stdoutData = Self.readBounded(
                output.fileHandleForReading,
                limit: maximumOutputBytes
            )
            async let stderrData = Self.readBounded(
                errorOutput.fileHandleForReading,
                limit: maximumOutputBytes
            )

            do {
                try await waitForExit(process)
            } catch {
                Self.stop(process)
                try? output.fileHandleForReading.close()
                try? errorOutput.fileHandleForReading.close()
                _ = await (stdoutData, stderrData)
                throw error
            }

            let (stdout, stderr) = await (stdoutData, stderrData)
            return ProcessResult(
                terminationStatus: process.terminationStatus,
                standardOutput: String(decoding: stdout, as: UTF8.self),
                standardError: String(decoding: stderr, as: UTF8.self)
            )
        } onCancel: {
            Self.stop(process)
            try? output.fileHandleForReading.close()
            try? errorOutput.fileHandleForReading.close()
        }
    }

    private func waitForExit(_ process: Process) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ProcessRunnerError.timedOut(timeout)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) async -> Data {
        await Task.detached(priority: .utility) {
            var captured = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return captured }
                let remaining = max(0, limit - captured.count)
                if remaining > 0 {
                    captured.append(chunk.prefix(remaining))
                }
            }
        }.value
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        usleep(100_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
