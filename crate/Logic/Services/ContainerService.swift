import Foundation

actor CLIContainerBackend: ContainerBackend {

    private let binaryPathProvider: @Sendable () -> String?

    init(binaryPathProvider: @escaping @Sendable () -> String? = {
        let stored = UserDefaults.standard.string(forKey: "containerBinaryPath")
        return BinaryLocator.resolveContainerBinary(preferredPath: stored)
    }) {
        self.binaryPathProvider = binaryPathProvider
    }

    private func resolvedBinary() throws -> String {
        guard let path = binaryPathProvider() else {
            throw BackendError.binaryNotFound
        }
        return path
    }

    // MARK: - Process execution

    @discardableResult
    private func run(_ args: [String]) async throws -> String {
        let binary = try resolvedBinary()
        let result = try await Self.runProcess(launchPath: binary, args: args)
        if result.exitCode != 0 {
            throw BackendError.commandFailed(
                command: "container " + args.joined(separator: " "),
                exit: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private static func runProcess(launchPath: String, args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Buffers accumulated on background queues; safe because terminationHandler runs after readers complete.
            let stdoutBuffer = DataBuffer()
            let stderrBuffer = DataBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any remaining buffered data.
                let trailingOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let trailingErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !trailingOut.isEmpty { stdoutBuffer.append(trailingOut) }
                if !trailingErr.isEmpty { stderrBuffer.append(trailingErr) }

                let out = String(decoding: stdoutBuffer.data, as: UTF8.self)
                let err = String(decoding: stderrBuffer.data, as: UTF8.self)
                continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Thread-safe append-only data buffer used by the readability handlers.
    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            storage.append(chunk)
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Streaming

    func streamContainerLogs(containerId: String, onLine: @escaping @Sendable (String) -> Void) async throws -> StreamHandle {
        let binary = try resolvedBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["logs", "-f", containerId]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let buffer = LineBuffer(onLine: onLine)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.feed(chunk)
        }

        // Construct the handle before running so terminationHandler is wired.
        let handle = StreamHandle(process: process, stdout: stdout, stderr: stderr)
        try process.run()
        return handle
    }

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func feed(_ chunk: Data) {
            let lines: [String] = {
                lock.lock(); defer { lock.unlock() }
                pending.append(chunk)
                var result: [String] = []
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
                    pending.removeSubrange(pending.startIndex...newlineIndex)
                    result.append(String(decoding: lineData, as: UTF8.self))
                }
                return result
            }()
            for line in lines {
                onLine(line)
            }
        }
    }

    // MARK: - Parsing

    private struct ContainerJSON: Decodable {
        struct Platform: Decodable { let os: String?; let architecture: String? }
        struct Image: Decodable { let reference: String? }
        struct Network: Decodable { let address: String? }
        struct MountTypeVolume: Decodable { let format: String?; let name: String? }
        struct MountType: Decodable { let volume: MountTypeVolume? }
        struct Mount: Decodable { let options: [String]?; let source: String?; let type: MountType?; let destination: String? }
        struct PublishedPort: Decodable {
            let proto: String?
            let hostPort: Int?
            let hostAddress: String?
            let containerPort: Int?
        }
        struct Config: Decodable {
            let id: String?
            let platform: Platform?
            let image: Image?
            let networks: [Network]?
            let mounts: [Mount]?
            let publishedPorts: [PublishedPort]?
        }
        let status: String?
        let networks: [Network]?
        let configuration: Config?
    }

    private struct ImageJSON: Decodable {
        struct Descriptor: Decodable {
            let mediaType: String?
            let digest: String?
            let size: Int?
        }
        let reference: String?
        let descriptor: Descriptor?
    }
    private struct VolumeJSON: Decodable {
        let name: String?
        let mountpoint: String?
        let source: String?
        let driver: String?
        let labels: [String: String]?
        let options: [String: String]?
        let createdAt: TimeInterval?
        let format: String?
    }

    /// Parse legacy whitespace-aligned `container list --all` output.
    func parseContainerList(_ text: String) -> [ContainerModel] {
        var lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 0 else { return [] }

        if let first = lines.first,
           first.lowercased().contains("id") && first.lowercased().contains("image") {
            lines.removeFirst()
        }

        var models: [ContainerModel] = []

        let pattern = #"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(\S+))?$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        for raw in lines {
            if let regex,
               let match = regex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: raw.utf16.count)) {
                func substring(_ idx: Int) -> String? {
                    guard idx <= match.numberOfRanges - 1 else { return nil }
                    let r = match.range(at: idx)
                    guard r.location != NSNotFound, let range = Range(r, in: raw) else { return nil }
                    return String(raw[range])
                }
                let id = substring(1) ?? ""
                let image = substring(2) ?? ""
                let os = substring(3)
                let arch = substring(4)
                let state = substring(5) ?? ""
                let addr = substring(6)
                models.append(ContainerModel(id: id, image: image, os: os, arch: arch, state: state, running: state == "running", addr: addr, mounts: [], ports: []))
                continue
            }

            let parts = raw.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map { String($0) }
            if parts.count >= 5 {
                let id = parts[0]
                let image = parts[1]
                let os = parts[2]
                let arch = parts[3]
                let state = parts[4]
                let addr = parts.count >= 6 ? parts[5] : nil
                models.append(ContainerModel(id: id, image: image, os: os, arch: arch, state: state, running: state == "running", addr: addr, mounts: [], ports: []))
            }
        }

        return models
    }

    func parseSystemStatus(_ text: String) -> String {
        if let statusLine = text
            .split(separator: "\n")
            .first(where: { $0.lowercased().contains("apiserver is") }) {
            return statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "unknown"
    }

    // MARK: - ContainerBackend

    func listAllContainers() async throws -> [ContainerModel] {
        let output = try await run(["list", "--all", "--format", "json"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BackendError.parseError("empty `container list` output")
        }
        let data = Data(output.utf8)
        let decoder = JSONDecoder()

        let items: [ContainerJSON]
        do {
            items = try decoder.decode([ContainerJSON].self, from: data)
        } catch {
            let fallback = parseContainerList(output)
            if fallback.isEmpty && trimmed != "[]" {
                throw BackendError.parseError("unrecognized `container list` output")
            }
            return fallback
        }

        return items.map { item in
            let cfg = item.configuration
            let id = cfg?.id ?? ""
            let imageRef = cfg?.image?.reference ?? ""
            let os = cfg?.platform?.os
            let arch = cfg?.platform?.architecture
            let state = item.status ?? "unknown"

            let addr: String? = {
                if let n = item.networks?.first?.address, !n.isEmpty { return n }
                if let n = cfg?.networks?.first?.address, !n.isEmpty { return n }
                return nil
            }()

            let mounts: [ContainerMount] = (cfg?.mounts ?? []).map { m in
                let v = m.type?.volume
                return ContainerMount(
                    source: m.source,
                    destination: m.destination,
                    volumeName: v?.name,
                    format: v?.format
                )
            }

            let ports: [ContainerPort] = (cfg?.publishedPorts ?? []).compactMap { p in
                guard let host = p.hostPort, let cport = p.containerPort else { return nil }
                return ContainerPort(proto: p.proto, hostAddress: p.hostAddress, hostPort: host, containerPort: cport)
            }

            return ContainerModel(id: id, image: imageRef, os: os, arch: arch, state: state, running: state == "running", addr: addr, mounts: mounts, ports: ports)
        }
    }

    func listAllImages() async throws -> [ImageModel] {
        let output = try await run(["image", "list", "--format", "json"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BackendError.parseError("empty `container image list` output")
        }
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        do {
            let items = try decoder.decode([ImageJSON].self, from: data)
            return items.map { item in
                let sizeBytes = item.descriptor?.size
                let sizeText = sizeBytes.map { Self.humanReadableBytes($0) }
                return ImageModel(
                    id: item.reference ?? "",
                    size: sizeText,
                    digest: item.descriptor?.digest,
                    mediaType: item.descriptor?.mediaType
                )
            }
        } catch {
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 1 else { return nil }
                let ref = String(parts[0])
                let size = parts.count > 1 ? String(parts[1]) : nil
                return ImageModel(id: ref, size: size, digest: nil, mediaType: nil)
            }
        }
    }

    private static func humanReadableBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    func listAllVolumes() async throws -> [VolumeModel] {
        let output = try await run(["volume", "list", "--format", "json"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BackendError.parseError("empty `container volume list` output")
        }
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        do {
            let items = try decoder.decode([VolumeJSON].self, from: data)
            return items.map { VolumeModel(
                id: $0.name ?? "",
                mountpoint: $0.mountpoint,
                source: $0.source,
                driver: $0.driver,
                labels: $0.labels,
                options: $0.options,
                createdAt: $0.createdAt,
                format: $0.format
            ) }
        } catch {
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 1 else { return nil }
                let name = String(parts[0])
                let mp = parts.count > 1 ? String(parts[1]) : nil
                return VolumeModel(id: name, mountpoint: mp, source: nil, driver: nil, labels: nil, options: nil, createdAt: nil, format: nil)
            }
        }
    }

    func systemStatus() async throws -> String {
        // `container system status` exits with non-zero when the apiserver is
        // not running, but the stderr contains the very information we want.
        // Treat that case as a successful "stopped" status instead of bubbling
        // up a commandFailed error.
        do {
            let output = try await run(["system", "status"])
            return parseSystemStatus(output)
        } catch let error as BackendError {
            if case let .commandFailed(_, _, stderr) = error {
                let lower = stderr.lowercased()
                if lower.contains("apiserver is not running")
                    || lower.contains("not registered with launchd") {
                    return parseSystemStatus(stderr)
                }
            }
            throw error
        }
    }

    func startContainer(containerId: String) async throws {
        try await run(["start", containerId])
    }

    func stopContainer(containerId: String) async throws {
        try await run(["stop", containerId])
    }

    func deleteContainer(containerId: String) async throws {
        try await run(["delete", containerId])
    }

    func startSystem() async throws {
        try await run(["system", "start"])
    }

    func stopSystem() async throws {
        try await run(["system", "stop"])
    }

    func createVolume(name: String, size: String?, options: [String], labels: [String]) async throws {
        var args: [String] = ["volume", "create", name]
        if let size, !size.isEmpty {
            args.append(contentsOf: ["-s", size])
        }
        for opt in options where !opt.isEmpty {
            args.append(contentsOf: ["--opt", opt])
        }
        for label in labels where !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }
        try await run(args)
    }

    func deleteVolume(name: String) async throws {
        try await run(["volume", "delete", name])
    }

    func createContainer(_ options: ContainerCreateOptions) async throws {
        var args: [String] = ["create"]
        args.append(contentsOf: ["--name", options.name])

        if options.removeOnExit { args.append("--rm") }
        if options.interactive { args.append("-i") }
        if options.tty { args.append("-t") }

        for env in options.env where !env.isEmpty {
            args.append(contentsOf: ["-e", env])
        }
        for label in options.labels where !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }
        for port in options.publishPorts where !port.isEmpty {
            args.append(contentsOf: ["--publish", port])
        }
        for dns in options.dns where !dns.isEmpty {
            args.append(contentsOf: ["--dns", dns])
        }
        if let workingDir = options.workingDir, !workingDir.isEmpty {
            args.append(contentsOf: ["--workdir", workingDir])
        }
        if let user = options.user, !user.isEmpty {
            args.append(contentsOf: ["--user", user])
        }
        if let entrypoint = options.entrypoint, !entrypoint.isEmpty {
            args.append(contentsOf: ["--entrypoint", entrypoint])
        }
        if let cpus = options.cpus, !cpus.isEmpty {
            args.append(contentsOf: ["--cpus", cpus])
        }
        if let memory = options.memory, !memory.isEmpty {
            args.append(contentsOf: ["--memory", memory])
        }
        if let platform = options.platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        } else {
            if let os = options.osValue, !os.isEmpty {
                args.append(contentsOf: ["--os", os])
            }
            if let arch = options.archValue, !arch.isEmpty {
                args.append(contentsOf: ["--arch", arch])
            }
        }
        if let network = options.network, !network.isEmpty {
            args.append(contentsOf: ["--network", network])
        }

        for (vol, target) in options.volumeMappings.sorted(by: { $0.key < $1.key }) {
            let trimmedVol = vol.trimmingCharacters(in: .whitespaces)
            let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
            guard !trimmedVol.isEmpty, !trimmedTarget.isEmpty else { continue }
            args.append(contentsOf: ["--volume", "\(trimmedVol):\(trimmedTarget)"])
        }

        args.append(options.image)

        for arg in options.command where !arg.isEmpty {
            args.append(arg)
        }

        try await run(args)
    }

    func killContainer(containerId: String, signal: String) async throws {
        var args: [String] = ["kill"]
        if !signal.isEmpty {
            args.append(contentsOf: ["--signal", signal])
        }
        args.append(containerId)
        try await run(args)
    }

    func inspectContainer(containerId: String) async throws -> String {
        try await run(["inspect", containerId])
    }

    func inspectImage(reference: String) async throws -> String {
        try await run(["image", "inspect", reference])
    }

    func inspectVolume(name: String) async throws -> String {
        try await run(["volume", "inspect", name])
    }

    func pullImage(reference: String, platform: String?) async throws {
        var args: [String] = ["image", "pull"]
        if let platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        args.append(reference)
        try await run(args)
    }

    func streamPullImage(reference: String,
                         platform: String?,
                         onLine: @escaping @Sendable (String) -> Void) async throws -> StreamHandle {
        let binary = try resolvedBinary()
        var args: [String] = ["image", "pull"]
        if let platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        args.append(reference)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outBuf = LineBuffer(onLine: onLine)
        let errBuf = LineBuffer(onLine: onLine)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            outBuf.feed(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            errBuf.feed(chunk)
        }

        let handle = StreamHandle(process: process, stdout: stdout, stderr: stderr)
        try process.run()
        return handle
    }

    func deleteImage(reference: String) async throws {
        try await run(["image", "delete", reference])
    }

    func tagImage(source: String, target: String) async throws {
        try await run(["image", "tag", source, target])
    }

    func pushImage(reference: String, platform: String?) async throws {
        var args: [String] = ["image", "push"]
        if let platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        args.append(reference)
        try await run(args)
    }

    func loadImage(fromArchive path: String) async throws {
        try await run(["image", "load", "--input", path])
    }

    func saveImage(reference: String, toArchive path: String, platform: String?) async throws {
        var args: [String] = ["image", "save", "--output", path]
        if let platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        args.append(reference)
        try await run(args)
    }

    func pruneImages() async throws {
        try await run(["image", "prune"])
    }

    func fetchLogs(containerId: String, options: LogsOptions) async throws -> String {
        var args: [String] = ["logs"]
        if options.boot { args.append("--boot") }
        if let tail = options.tail {
            args.append(contentsOf: ["-n", String(tail)])
        }
        args.append(containerId)
        return try await run(args)
    }

}
