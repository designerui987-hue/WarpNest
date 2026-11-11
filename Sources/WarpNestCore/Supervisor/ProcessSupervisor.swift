import Foundation

/// Thread-safe ring buffer for capturing process console output up to a maximum size.
public final class LogRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    public let maxCapacity: Int

    public init(maxCapacity: Int = 2000) {
        self.maxCapacity = maxCapacity
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > maxCapacity {
            lines.removeFirst(lines.count - maxCapacity)
        }
    }

    public func getAllLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func getJoinedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}

/// Result of a process termination.
public struct ProcessExitStatus: Sendable, Equatable {
    public let exitCode: Int32
    public let wasCancelled: Bool

    public init(exitCode: Int32, wasCancelled: Bool = false) {
        self.exitCode = exitCode
        self.wasCancelled = wasCancelled
    }
}

/// Errors thrown by the ProcessSupervisor.
public enum ProcessSupervisorError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case executionFailed(String)
    case processAlreadyRunning(Int32)
    case processNotRunning

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Executable file was not found at path: \(path)"
        case .executionFailed(let reason):
            return "Process launch failed: \(reason)"
        case .processAlreadyRunning(let pid):
            return "Process is already running with PID \(pid)"
        case .processNotRunning:
            return "No supervised process is currently active."
        }
    }
}

/// Actor that supervises process execution without shell interpolation.
/// Handles concurrent draining of stdout and stderr into a bounded ring buffer.
public actor ProcessSupervisor {
    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private let logBuffer: LogRingBuffer
    private var terminationContinuation: CheckedContinuation<ProcessExitStatus, Never>?
    private var cancelled: Bool = false

    public init(logBuffer: LogRingBuffer = LogRingBuffer()) {
        self.logBuffer = logBuffer
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public var processIdentifier: Int32? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    /// Launches an executable with explicit arguments, working directory, and environment.
    /// Never passes strings through a shell interpreter.
    public func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessExitStatus {
        guard !isRunning else {
            throw ProcessSupervisorError.processAlreadyRunning(process?.processIdentifier ?? -1)
        }

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessSupervisorError.executableNotFound(executableURL.path)
        }

        cancelled = false
        let p = Process()
        p.executableURL = executableURL
        p.arguments = arguments
        if let workingDirectory = workingDirectory {
            p.currentDirectoryURL = workingDirectory
        }

        // Merge parent environment with overrides
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            env[k] = v
        }
        p.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        let buffer = self.logBuffer

        // Drain stdout asynchronously
        stdoutTask = Task.detached {
            let fileHandle = stdoutPipe.fileHandleForReading
            do {
                for try await line in fileHandle.bytes.lines {
                    buffer.append("[STDOUT] " + line)
                }
            } catch {
                // Pipe closed
            }
        }

        // Drain stderr asynchronously
        stderrTask = Task.detached {
            let fileHandle = stderrPipe.fileHandleForReading
            do {
                for try await line in fileHandle.bytes.lines {
                    buffer.append("[STDERR] " + line)
                }
            } catch {
                // Pipe closed
            }
        }

        self.process = p

        do {
            try p.run()
            buffer.append("[SUPERVISOR] Process started with PID: \(p.processIdentifier)")
        } catch {
            self.process = nil
            buffer.append("[SUPERVISOR] Failed to launch: \(error.localizedDescription)")
            throw ProcessSupervisorError.executionFailed(error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            self.terminationContinuation = continuation
            p.terminationHandler = { [weak self] proc in
                Task { [weak self] in
                    await self?.handleTermination(exitCode: proc.terminationStatus)
                }
            }
        }
    }

    private func handleTermination(exitCode: Int32) {
        logBuffer.append("[SUPERVISOR] Process exited with status code: \(exitCode)")
        let status = ProcessExitStatus(exitCode: exitCode, wasCancelled: self.cancelled)
        terminationContinuation?.resume(returning: status)
        terminationContinuation = nil
        process = nil
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
    }

    /// Gracefully requests termination via SIGTERM, then forces SIGKILL if still running.
    public func terminate() async {
        guard let p = process, p.isRunning else { return }
        cancelled = true
        logBuffer.append("[SUPERVISOR] Terminating process (PID: \(p.processIdentifier))...")
        p.terminate()

        // Wait up to 2 seconds for clean exit before forcing
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !p.isRunning { return }
        }

        if p.isRunning {
            logBuffer.append("[SUPERVISOR] Process did not exit gracefully, sending SIGKILL...")
            kill(p.processIdentifier, SIGKILL)
        }
    }

    public func getLogs() -> [String] {
        logBuffer.getAllLines()
    }
}
