import Foundation

/// Persistent record of containers we have seen, kept in
/// `~/Library/Application Support/crate/history.json`.
///
/// The Apple `container` runtime keeps no tombstones — once `container delete`
/// (or an auto-reap) runs, the container is unrecoverable from the runtime's
/// perspective. This store lets the UI surface a "Recently Deleted" view and
/// recreate from the captured options.
actor ContainerHistoryStore {
    private var entries: [String: ContainerHistoryEntry] = [:]
    private var loaded = false

    private let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.fileURL = support
                .appendingPathComponent("crate", isDirectory: true)
                .appendingPathComponent("history.json", isDirectory: false)
        }
    }

    func all() -> [ContainerHistoryEntry] {
        loadIfNeeded()
        return Array(entries.values)
    }

    func activeIDs() -> Set<String> {
        loadIfNeeded()
        return Set(entries.values.filter { !$0.isDeleted }.map(\.id))
    }

    func entry(for id: String) -> ContainerHistoryEntry? {
        loadIfNeeded()
        return entries[id]
    }

    /// Insert a new entry, or refresh the timestamps/options of an existing
    /// one. Re-seeing a previously-deleted id clears the tombstone so an id
    /// that was reused for a new container shows up as live again.
    func upsert(_ entry: ContainerHistoryEntry) {
        loadIfNeeded()
        if var existing = entries[entry.id] {
            existing.lastSeen = entry.lastSeen
            existing.deletedAt = nil
            existing.options = entry.options
            existing.image = entry.image
            entries[entry.id] = existing
        } else {
            entries[entry.id] = entry
        }
        save()
    }

    func touch(ids: Set<String>, at date: Date = Date()) {
        loadIfNeeded()
        var dirty = false
        for id in ids {
            if var e = entries[id] {
                e.lastSeen = date
                if e.deletedAt != nil { e.deletedAt = nil }
                entries[id] = e
                dirty = true
            }
        }
        if dirty { save() }
    }

    func markDeleted(ids: Set<String>, at date: Date = Date()) {
        loadIfNeeded()
        var dirty = false
        for id in ids {
            if var e = entries[id], e.deletedAt == nil {
                e.deletedAt = date
                entries[id] = e
                dirty = true
            }
        }
        if dirty { save() }
    }

    func forget(_ id: String) {
        loadIfNeeded()
        if entries.removeValue(forKey: id) != nil { save() }
    }

    func clearDeleted() {
        loadIfNeeded()
        let before = entries.count
        entries = entries.filter { !$0.value.isDeleted }
        if entries.count != before { save() }
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([ContainerHistoryEntry].self, from: data)
            for e in list { entries[e.id] = e }
        } catch {
            // A corrupt history file shouldn't crash the app — start fresh and
            // overwrite on the next save.
            entries.removeAll()
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Array(entries.values))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal — keep the in-memory entries.
        }
    }
}
