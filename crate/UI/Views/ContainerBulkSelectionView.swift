import SwiftUI

/// Detail panel shown when more than one container is selected. Lifts the
/// common lifecycle actions (start / stop / restart / delete) to the whole
/// selection, so the user doesn't have to fall back to a context menu.
struct ContainerBulkSelectionView: View {
    let ids: Set<String>
    @EnvironmentObject private var vm: ContainerViewModel
    @State private var isConfirmingDelete: Bool = false
    @State private var inflight: BulkAction? = nil
    @State private var progress: BulkProgress? = nil

    enum BulkAction { case start, stop, restart, delete }

    struct BulkProgress {
        var done: Int
        var total: Int
    }

    private var containers: [ContainerModel] {
        vm.containers
            .filter { ids.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    private var anyRunning: Bool { containers.contains { $0.running } }
    private var anyStopped: Bool { containers.contains { !$0.running } }
    private var busy: Bool { inflight != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(containers.count) containers selected")
                        .font(.title3)
                        .bold()

                    Text("Lifecycle actions apply to every container in the selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 6)

                    ForEach(containers) { c in
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.id).font(.system(.body, design: .default))
                                Text(c.image)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(c.state)
                                .font(.caption)
                                .foregroundStyle(c.running ? .green : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(c.running ? Color.green.opacity(0.12)
                                                        : Color(nsColor: .controlBackgroundColor))
                                )
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(15)
            }
        }
        .navigationTitle("\(containers.count) Containers")
        .navigationSubtitle("\(containers.filter { $0.running }.count) running")
        .confirmationDialog(
            "Delete \(containers.count) containers?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                runBulk(.delete, "Deleting") { id in await vm.deleteContainer(id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button {
                runBulk(.start, "Starting") { id in await vm.startContainer(id) }
            } label: {
                bulkLabel(.start, pending: "Starting", idle: "Start All", systemImage: "play.fill")
            }
            .disabled(!anyStopped || busy)
            .help("Start every stopped container in the selection")

            Button {
                runBulk(.stop, "Stopping") { id in await vm.stopContainer(id) }
            } label: {
                bulkLabel(.stop, pending: "Stopping", idle: "Stop All", systemImage: "stop.fill")
            }
            .disabled(!anyRunning || busy)
            .help("Stop every running container in the selection")

            Button {
                runBulk(.restart, "Restarting") { id in await vm.restartContainer(id) }
            } label: {
                bulkLabel(.restart, pending: "Restarting", idle: "Restart All", systemImage: "arrow.trianglehead.counterclockwise")
            }
            .disabled(busy)
            .help("Restart every container in the selection")

            Spacer()

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                bulkLabel(.delete, pending: "Deleting", idle: "Delete All", systemImage: "trash")
            }
            .disabled(busy)
            .help("Delete every container in the selection")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func bulkLabel(_ activeWhen: BulkAction,
                           pending: String,
                           idle: String,
                           systemImage: String) -> some View {
        if inflight == activeWhen, let progress {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(pending) \(progress.done)/\(progress.total)…")
            }
        } else {
            Label(idle, systemImage: systemImage)
        }
    }

    private func runBulk(_ action: BulkAction,
                         _ verb: String,
                         _ body: @escaping (String) async -> Void) {
        guard inflight == nil else { return }
        let snapshot = containers.map(\.id)
        inflight = action
        progress = BulkProgress(done: 0, total: snapshot.count)
        Task {
            for (idx, id) in snapshot.enumerated() {
                await body(id)
                progress = BulkProgress(done: idx + 1, total: snapshot.count)
            }
            inflight = nil
            progress = nil
        }
    }
}
