import Foundation
import SwiftUI

@MainActor
class ContainerViewModel: ObservableObject {
    @Published var containers: [ContainerModel] = []
    @Published var systemStatus: String = "Unknown" {
        didSet {
            isSystemRunning = deriveIsSystemRunning(from: systemStatus)
        }
    }
    @Published var isSystemRunning: Bool = false
    /// Currently-displayed error. Setting it to nil triggers the next queued
    /// error (if any) on the next runloop, so back-to-back failures don't
    /// silently overwrite each other.
    @Published var errorMessage: String? = nil {
        didSet {
            guard errorMessage == nil, !errorQueue.isEmpty else { return }
            let next = errorQueue.removeFirst()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = next
            }
        }
    }
    @Published var logs: [LogLine] = []
    private var nextLogID: UInt64 = 0

    /// Single line emitted by the container log stream. The `id` is monotonic so
    /// trimming the buffer's prefix doesn't renumber the suffix.
    struct LogLine: Identifiable, Hashable {
        let id: UInt64
        let text: String
    }

    @Published var images: [ImageModel] = []
    @Published var volumes: [VolumeModel] = []
    @Published var history: [ContainerHistoryEntry] = []

    /// When set, the container-create sheet should appear pre-populated with this volume name.
    @Published var pendingCreateContainerVolume: String? = nil

    private let backend: any ContainerBackend
    private let historyStore: ContainerHistoryStore
    private var pollingTask: Task<Void, Never>? = nil
    private var logStream: StreamHandle? = nil
    private var errorQueue: [String] = []
    /// IDs we've already snapshotted (or are currently snapshotting) this session,
    /// so a quick succession of refreshes doesn't fan out duplicate `container
    /// inspect` calls for the same new container.
    private var snapshotsInFlight: Set<String> = []

    init(backend: any ContainerBackend = CLIContainerBackend(),
         historyStore: ContainerHistoryStore = ContainerHistoryStore()) {
        self.backend = backend
        self.historyStore = historyStore
        Task { [weak self] in await self?.reloadHistory() }
    }

    /// Queue an error for display. If the banner is empty it shows immediately;
    /// otherwise it queues so the current message has time to be read. Identical
    /// duplicate messages are coalesced.
    private func pushError(_ message: String) {
        if errorMessage == nil {
            errorMessage = message
        } else if errorMessage != message, !errorQueue.contains(message) {
            errorQueue.append(message)
        }
    }

    private func deriveIsSystemRunning(from text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("apiserver is running") { return true }
        if lower.contains("apiserver is not running") { return false }
        return false
    }

    private func performRefresh() async {
        // First: ask the system whether it is running. If this fails outright
        // (e.g. binary not found), surface the error and stop — list calls
        // would only produce noisier failures.
        do {
            self.systemStatus = try await backend.systemStatus()
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }

        // System is stopped → nothing more to fetch. Clear the lists so the
        // "Service not running" UI shows cleanly and don't post error banners
        // for list calls that we know will fail.
        guard isSystemRunning else {
            self.containers = []
            self.images = []
            self.volumes = []
            self.errorMessage = nil
            return
        }

        // System is up — refresh the three lists in parallel.
        async let containersTask = backend.listAllContainers()
        async let imagesTask = backend.listAllImages()
        async let volumesTask = backend.listAllVolumes()

        var lastError: Error?
        let previousContainers = self.containers
        let previousImages = self.images
        let previousVolumes = self.volumes

        do {
            let fresh = try await containersTask
            // Anti-flicker: a single empty response while we just had containers
            // is almost always a transient state — keep the old list for one cycle.
            if fresh.isEmpty, !previousContainers.isEmpty {
                // skip
            } else {
                self.containers = fresh
                await reconcileHistory(currentContainers: fresh)
            }
        } catch {
            lastError = error
        }

        do {
            let fresh = try await imagesTask
            if fresh.isEmpty, !previousImages.isEmpty {
                // skip
            } else {
                self.images = fresh
            }
        } catch {
            lastError = error
        }

        do {
            let fresh = try await volumesTask
            if fresh.isEmpty, !previousVolumes.isEmpty {
                // skip
            } else {
                self.volumes = fresh
            }
        } catch {
            lastError = error
        }

        // Don't blink the banner for transient parseErrors on a single poll cycle.
        if let error = lastError, !isTransientParseError(error) {
            pushError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        } else if lastError == nil {
            self.errorMessage = nil
        }
    }

    private func isTransientParseError(_ error: Error) -> Bool {
        if case .parseError = (error as? BackendError) { return true }
        return false
    }

    func refresh() {
        Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// Awaitable variant of `refresh()` for callers that need to know when the
    /// next snapshot is in place (e.g. closing a sheet after a streaming pull).
    func refreshAsync() async {
        await performRefresh()
    }

    func getRunningContainersAmount() -> Int {
        containers.filter { $0.running || $0.state.lowercased() == "running" }.count
    }

    func startPolling(interval seconds: TimeInterval = 5.0) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    // Sleep throws on cancellation — exit immediately instead of
                    // running one more (now-redundant) refresh after the user
                    // cancelled or the VM is going away.
                    break
                }
                await self.performRefresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func startLogs(for id: String) async {
        stopLogs()
        logs.removeAll()
        do {
            let handle = try await backend.streamContainerLogs(containerId: id) { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.appendLogLine(line)
                }
            }
            self.logStream = handle
        } catch {
            pushError("Failed to stream logs: \(error)")
        }
    }

    func stopLogs() {
        logStream?.cancel()
        logStream = nil
    }

    func appendLogLine(_ text: String) {
        nextLogID &+= 1
        logs.append(LogLine(id: nextLogID, text: text))
        if logs.count > 2000 {
            logs.removeFirst(logs.count - 2000)
        }
    }

    func replaceLogs(with snapshot: [String]) {
        var built: [LogLine] = []
        built.reserveCapacity(snapshot.count)
        for line in snapshot {
            nextLogID &+= 1
            built.append(LogLine(id: nextLogID, text: line))
        }
        logs = built
    }

    func startSystem() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.startSystem()
            } catch {
                pushError((error as? LocalizedError)?.errorDescription ?? "Failed to start system: \(error)")
            }
            await self.performRefresh()
        }
    }

    func stopSystem() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.stopSystem()
            } catch {
                pushError((error as? LocalizedError)?.errorDescription ?? "Failed to stop system: \(error)")
            }
            await self.performRefresh()
        }
    }

    func startContainer(_ id: String) async {
        guard let container = containers.first(where: { $0.id == id }) else {
            pushError("Container not found: \(id)")
            return
        }
        guard !container.running else { return }
        do {
            try await backend.startContainer(containerId: id)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to start container: \(error)")
        }
        await performRefresh()
    }

    func stopContainer(_ id: String) async {
        do {
            try await backend.stopContainer(containerId: id)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to stop container: \(error)")
        }
        await performRefresh()
    }

    func deleteContainer(_ id: String) async {
        do {
            try await backend.deleteContainer(containerId: id)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to delete container: \(error)")
        }
        await performRefresh()
    }

    func restartContainer(_ id: String) async {
        do {
            try await backend.stopContainer(containerId: id)
            try await backend.startContainer(containerId: id)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to restart container: \(error)")
        }
        await performRefresh()
    }

    func createVolume(name: String, size: String? = nil, options: [String] = [], labels: [String] = []) async {
        do {
            try await backend.createVolume(name: name, size: size, options: options, labels: labels)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to create volume: \(error)")
        }
        await performRefresh()
    }

    func deleteVolume(name: String) async {
        do {
            try await backend.deleteVolume(name: name)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to delete volume: \(error)")
        }
        await performRefresh()
    }

    func createContainer(_ options: ContainerCreateOptions) async {
        do {
            try await backend.createContainer(options)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to create container: \(error)")
        }
        await performRefresh()
    }

    func killContainer(_ id: String, signal: String) async {
        do {
            try await backend.killContainer(containerId: id, signal: signal)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to kill container: \(error)")
        }
        await performRefresh()
    }

    func inspectContainer(_ id: String) async -> String? {
        do {
            return try await backend.inspectContainer(containerId: id)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to inspect container: \(error)")
            return nil
        }
    }

    /// Fetch a container's full configuration and convert it into options that
    /// can pre-fill the create dialog, with a suggested unique name.
    func cloneOptions(for id: String) async -> ContainerCreateOptions? {
        guard let json = await inspectContainer(id) else { return nil }
        let suggested = uniqueCloneName(basedOn: id)
        guard let opts = ContainerCreateOptions.from(inspectJSON: json, suggestedName: suggested) else {
            pushError("Could not parse container configuration for cloning.")
            return nil
        }
        return opts
    }

    private func uniqueCloneName(basedOn id: String) -> String {
        let existing = Set(containers.map { $0.id })
        let base = "\(id)-copy"
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - History reconciliation

    /// Compare the freshly-fetched container list against the persistent
    /// history. New ids get a snapshot inspect; ids that disappeared get a
    /// tombstone with `deletedAt = now`.
    private func reconcileHistory(currentContainers: [ContainerModel]) async {
        let currentIDs = Set(currentContainers.map(\.id))
        let activeInHistory = await historyStore.activeIDs()

        let missing = activeInHistory.subtracting(currentIDs)
        if !missing.isEmpty {
            await historyStore.markDeleted(ids: missing)
        }

        if !currentIDs.isEmpty {
            await historyStore.touch(ids: currentIDs)
        }

        // Snapshot any id we haven't recorded yet. Inspect calls are async, so
        // we fire them off without blocking the refresh; the history view will
        // pick them up as they land.
        let knownIDs = Set((await historyStore.all()).map(\.id))
        let newIDs = currentIDs.subtracting(knownIDs).subtracting(snapshotsInFlight)
        if !newIDs.isEmpty {
            snapshotsInFlight.formUnion(newIDs)
            for id in newIDs {
                let imageForId = currentContainers.first(where: { $0.id == id })?.image
                Task { [weak self] in
                    await self?.snapshotForHistory(id: id, fallbackImage: imageForId)
                }
            }
        }

        await reloadHistory()
    }

    private func snapshotForHistory(id: String, fallbackImage: String?) async {
        defer { snapshotsInFlight.remove(id) }
        guard let json = await inspectContainer(id) else { return }
        // Reuse the clone parser but reset the suggested-new-name so the
        // stored options reflect the original id; we'll re-derive a unique
        // name on recreate.
        guard var opts = ContainerCreateOptions.from(inspectJSON: json, suggestedName: id) else { return }
        opts.name = id
        let now = Date()
        let entry = ContainerHistoryEntry(
            id: id,
            image: opts.image.isEmpty ? (fallbackImage ?? "") : opts.image,
            firstSeen: now,
            lastSeen: now,
            deletedAt: nil,
            options: opts
        )
        await historyStore.upsert(entry)
        await reloadHistory()
    }

    private func reloadHistory() async {
        let all = await historyStore.all()
        self.history = all.sorted { lhs, rhs in
            // Deleted-first, most-recent first.
            let l = lhs.deletedAt ?? lhs.lastSeen
            let r = rhs.deletedAt ?? rhs.lastSeen
            return l > r
        }
    }

    /// Build create-options to recreate a previously-deleted container. The
    /// stored options keep the original name; this picks a non-colliding name
    /// from the current list so the recreate flow doesn't fail with "already
    /// exists" if the user happens to still have a same-named container.
    func recreateOptions(from entry: ContainerHistoryEntry) -> ContainerCreateOptions {
        var opts = entry.options
        opts.name = uniqueCloneName(basedOn: entry.id)
        return opts
    }

    func forgetHistoryEntry(_ id: String) async {
        await historyStore.forget(id)
        await reloadHistory()
    }

    func clearDeletedHistory() async {
        await historyStore.clearDeleted()
        await reloadHistory()
    }

    func inspectImage(_ reference: String) async -> String? {
        do {
            return try await backend.inspectImage(reference: reference)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to inspect image: \(error)")
            return nil
        }
    }

    /// Fetch and parse `container image inspect` into a structured view.
    func inspectImageDetails(_ reference: String) async -> ImageInspect? {
        guard let json = await inspectImage(reference) else { return nil }
        return ImageInspect.parse(json)
    }

    func inspectVolume(_ name: String) async -> String? {
        do {
            return try await backend.inspectVolume(name: name)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to inspect volume: \(error)")
            return nil
        }
    }

    func pullImage(reference: String, platform: String?) async {
        do {
            try await backend.pullImage(reference: reference, platform: platform)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to pull image: \(error)")
        }
        await performRefresh()
    }

    /// Start a streaming pull. The returned handle's `waitUntilDone()` resolves
    /// when the CLI exits; `cancel()` terminates it; `deinit` cleans up if it's
    /// dropped without explicit teardown.
    func streamPullImage(reference: String,
                         platform: String?,
                         onLine: @escaping @Sendable (String) -> Void) async -> StreamHandle? {
        do {
            return try await backend.streamPullImage(reference: reference, platform: platform, onLine: onLine)
        } catch {
            pushError("Failed to start pull: \(error)")
            return nil
        }
    }

    func deleteImage(reference: String) async {
        do {
            try await backend.deleteImage(reference: reference)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to delete image: \(error)")
        }
        await performRefresh()
    }

    func tagImage(source: String, target: String) async {
        do {
            try await backend.tagImage(source: source, target: target)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to tag image: \(error)")
        }
        await performRefresh()
    }

    func pushImage(reference: String, platform: String?) async {
        do {
            try await backend.pushImage(reference: reference, platform: platform)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to push image: \(error)")
        }
    }

    func loadImage(from path: String) async {
        do {
            try await backend.loadImage(fromArchive: path)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to load image: \(error)")
        }
        await performRefresh()
    }

    func saveImage(reference: String, to path: String, platform: String?) async {
        do {
            try await backend.saveImage(reference: reference, toArchive: path, platform: platform)
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to save image: \(error)")
        }
    }

    func pruneImages() async {
        do {
            try await backend.pruneImages()
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to prune images: \(error)")
        }
        await performRefresh()
    }

    func fetchLogs(for id: String, tail: Int?) async -> String? {
        do {
            return try await backend.fetchLogs(containerId: id, options: LogsOptions(tail: tail))
        } catch {
            pushError((error as? LocalizedError)?.errorDescription ?? "Failed to fetch logs: \(error)")
            return nil
        }
    }


}
