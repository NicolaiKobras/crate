import Foundation

enum BackendError: Error, LocalizedError {
    case binaryNotFound
    case commandFailed(command: String, exit: Int32, stderr: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "The `container` binary could not be located. Set its path in Settings."
        case .commandFailed(let command, let exit, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "`\(command)` failed with exit code \(exit)."
            }

// MARK: - StreamHandle

/// Owns the lifecycle of a streamed `Process` plus its stdout/stderr pipes.
/// `cancel()` is idempotent and runs in `deinit`, so the child cannot be
/// orphaned by a UI dismiss that forgets to clean up explicitly. Callers can
/// also `await waitUntilDone()` to be notified when the underlying CLI exits.
final class StreamHandle: @unchecked Sendable {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let lock = NSLock()
    private var cancelled = false
    private var terminated = false
    private var exitCode: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(code: proc.terminationStatus)
        }
    }

    private func handleTermination(code: Int32) {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        for c in pending { c.resume(returning: code) }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for c in pending { c.resume(returning: -1) }
    }

    /// Resumes when the streamed process exits or `cancel()` is called.
    /// Returns the exit code (or -1 on cancellation).
    func waitUntilDone() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if terminated {
                let code = exitCode
                lock.unlock()
                continuation.resume(returning: code)
                return
            }
            if cancelled {
                lock.unlock()
                continuation.resume(returning: -1)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    deinit { cancel() }
}
            return "`\(command)` failed (exit \(exit)): \(trimmed)"
        case .parseError(let detail):
            return "Failed to parse CLI output: \(detail)"
        }
    }
}

/// Options for the create-container call. Mirrors the flag surface of `container create`.
struct ContainerCreateOptions: Sendable, Codable, Hashable {
    var name: String
    var image: String

    var command: [String] = []
    var env: [String] = []                  // KEY=VALUE
    var labels: [String] = []               // key=value
    var publishPorts: [String] = []         // host[:host-ip]:container[/proto]
    var workingDir: String? = nil
    var user: String? = nil
    var entrypoint: String? = nil
    var cpus: String? = nil                 // e.g. "2"
    var memory: String? = nil               // e.g. "512M"
    var osValue: String? = nil
    var archValue: String? = nil
    var platform: String? = nil
    var network: String? = nil
    var dns: [String] = []
    var removeOnExit: Bool = false
    var interactive: Bool = false
    var tty: Bool = false

    /// volume name -> target path
    var volumeMappings: [String: String] = [:]
}

/// Options for fetching logs (non-follow path).
struct LogsOptions: Sendable {
    var tail: Int? = nil
    var boot: Bool = false
}

protocol ContainerBackend: Sendable {
    func listAllContainers() async throws -> [ContainerModel]
    func listAllImages() async throws -> [ImageModel]
    func listAllVolumes() async throws -> [VolumeModel]

    func systemStatus() async throws -> String

    func startContainer(containerId: String) async throws
    func stopContainer(containerId: String) async throws
    func deleteContainer(containerId: String) async throws
    func killContainer(containerId: String, signal: String) async throws

    func inspectContainer(containerId: String) async throws -> String
    func inspectImage(reference: String) async throws -> String
    func inspectVolume(name: String) async throws -> String

    func startSystem() async throws
    func stopSystem() async throws

    func createVolume(name: String, size: String?, options: [String], labels: [String]) async throws
    func deleteVolume(name: String) async throws

    func createContainer(_ options: ContainerCreateOptions) async throws

    func pullImage(reference: String, platform: String?) async throws
    func streamPullImage(reference: String,
                         platform: String?,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> StreamHandle
    func deleteImage(reference: String) async throws
    func tagImage(source: String, target: String) async throws
    func pushImage(reference: String, platform: String?) async throws
    func loadImage(fromArchive path: String) async throws
    func saveImage(reference: String, toArchive path: String, platform: String?) async throws
    func pruneImages() async throws

    func fetchLogs(containerId: String, options: LogsOptions) async throws -> String
    func streamContainerLogs(containerId: String, onLine: @escaping @Sendable (String) -> Void) async throws -> StreamHandle
}

// MARK: - StreamHandle

/// Owns the lifecycle of a streamed `Process` plus its stdout/stderr pipes.
/// `cancel()` is idempotent and runs in `deinit`, so the child cannot be
/// orphaned by a UI dismiss that forgets to clean up explicitly. Callers can
/// also `await waitUntilDone()` to be notified when the underlying CLI exits.
final class StreamHandle: @unchecked Sendable {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let lock = NSLock()
    private var cancelled = false
    private var terminated = false
    private var exitCode: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(code: proc.terminationStatus)
        }
    }

    private func handleTermination(code: Int32) {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        for c in pending { c.resume(returning: code) }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for c in pending { c.resume(returning: -1) }
    }

    /// Resumes when the streamed process exits or `cancel()` is called.
    /// Returns the exit code (or -1 on cancellation).
    func waitUntilDone() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if terminated {
                let code = exitCode
                lock.unlock()
                continuation.resume(returning: code)
                return
            }
            if cancelled {
                lock.unlock()
                continuation.resume(returning: -1)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    deinit { cancel() }
}
