import Foundation

/// Thread-safe ring buffer for capturing process console output up to a maximum size and byte limit.
public final class LogRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var totalBytes: Int = 0
    public let maxCapacity: Int
    public let maxBytes: Int
    private var onLineAdded: (@Sendable (String) -> Void)?

    public init(
        maxCapacity: Int = 2000,
        maxBytes: Int = 1_048_576, // 1 MB byte retention limit (WN-04 / N09)
        onLineAdded: (@Sendable (String) -> Void)? = nil
    ) {
        self.maxCapacity = maxCapacity
        self.maxBytes = maxBytes
        self.onLineAdded = onLineAdded
    }

    public func setLineHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.onLineAdded = handler
    }

    public func append(_ rawLine: String) {
        let handler: (@Sendable (String) -> Void)?
        lock.lock()

        // Chunk lines larger than 4KB to prevent unbounded line growth without newlines
        let maxLineLength = 4096
        var remaining = rawLine[...]
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(maxLineLength))
            remaining = remaining.dropFirst(maxLineLength)

            let byteCount = chunk.utf8.count
            lines.append(chunk)
            totalBytes += byteCount

            while lines.count > maxCapacity || (totalBytes > maxBytes && !lines.isEmpty) {
                let removed = lines.removeFirst()
                totalBytes -= removed.utf8.count
            }
        }

        handler = onLineAdded
        lock.unlock()
        handler?(rawLine)
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
        totalBytes = 0
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
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let logBuffer: LogRingBuffer
    private var terminationContinuation: CheckedContinuation<ProcessExitStatus, Never>?
    private var cancelled: Bool = false
    private var activePID: Int32?

    public init(logBuffer: LogRingBuffer = LogRingBuffer()) {
        self.logBuffer = logBuffer
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public var processIdentifier: Int32? {
        activePID
    }

    /// Launches an executable with explicit arguments, working directory, and environment.
    /// Never passes strings through a shell interpreter.
    public func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        onSpawn: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> ProcessExitStatus {
        guard !isRunning else {
            throw ProcessSupervisorError.processAlreadyRunning(activePID ?? -1)
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

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        let buffer = self.logBuffer

        // Asynchronous non-blocking readability handlers prevent buffer backpressure deadlocks (WN-02/WN-04)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                let lines = str.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    buffer.append("[STDOUT] " + line)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                let lines = str.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    buffer.append("[STDERR] " + line)
                }
            }
        }

        self.process = p

        do {
            try p.run()
            self.activePID = p.processIdentifier
            buffer.append("[SUPERVISOR] Process started with PID: \(p.processIdentifier)")
            onSpawn?(p.processIdentifier)
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.process = nil
            self.activePID = nil
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

    private func handleTermination(exitCode: Int32) async {
        // Stop readability handlers cleanly to release file handles
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining bytes that arrived before EOF
        if let outHandle = stdoutPipe?.fileHandleForReading {
            let data = outHandle.readDataToEndOfFile()
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    logBuffer.append("[STDOUT] " + line)
                }
            }
        }
        if let errHandle = stderrPipe?.fileHandleForReading {
            let data = errHandle.readDataToEndOfFile()
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    logBuffer.append("[STDERR] " + line)
                }
            }
        }

        logBuffer.append("[SUPERVISOR] Process exited with status code: \(exitCode)")
        let status = ProcessExitStatus(exitCode: exitCode, wasCancelled: self.cancelled)
        terminationContinuation?.resume(returning: status)
        terminationContinuation = nil
        process = nil
        activePID = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Gracefully requests termination via SIGTERM, then forces SIGKILL (and process group kill) if still running.
    public func terminate() async {
        guard let p = process, p.isRunning else { return }
        cancelled = true
        let pid = p.processIdentifier
        logBuffer.append("[SUPERVISOR] Terminating process (PID: \(pid))...")
        p.terminate()

        // Wait up to 2 seconds for clean exit before forcing
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !p.isRunning { return }
        }

        if p.isRunning {
            logBuffer.append("[SUPERVISOR] Process did not exit gracefully, sending SIGKILL...")
            // Only kill process group if the process is verified to be the group leader (WN-04)
            let pgid = getpgid(pid)
            if pgid == pid {
                kill(-pid, SIGKILL)
            }
            kill(pid, SIGKILL)
        }
    }

    public func getLogs() -> [String] {
        logBuffer.getAllLines()
    }
}
