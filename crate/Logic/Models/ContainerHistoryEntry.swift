import Foundation

/// Snapshot of a container we have seen at least once, kept so the UI can
/// surface a "Recently Deleted" list after the runtime reaps the container.
struct ContainerHistoryEntry: Identifiable, Codable, Hashable {
    /// Original container id as reported by `container list`. Dedup key in the
    /// history store.
    let id: String
    var image: String
    var firstSeen: Date
    var lastSeen: Date
    /// Set when the container disappears from the runtime's list. Nil means we
    /// still see it live on the current refresh.
    var deletedAt: Date?
    /// Captured from `container inspect` at first sighting, used to one-click
    /// recreate the container after deletion.
    var options: ContainerCreateOptions

    var isDeleted: Bool { deletedAt != nil }
}
