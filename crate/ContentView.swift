import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @State private var sidebarSelection: SidebarSection? = .containers
    @State private var selectedContainerID: String?
    @State private var selectedContainerIDs: Set<String> = []
    @State private var selectedImageID: String?
    @State private var selectedVolumeID: String?
    @State private var selectedVolumeIDs: Set<String> = []

    @State private var isPresentingAddVolume: Bool = false
    @State private var isConfirmingDeleteVolume: Bool = false
    @State private var isConfirmingDeleteContainer: Bool = false

    @State private var isPresentingAddContainer: Bool = false
    @State private var isPresentingCloneContainer: Bool = false
    @State private var cloneOptions: ContainerCreateOptions? = nil
    @State private var isPresentingRecreate: Bool = false
    @State private var recreateOptions: ContainerCreateOptions? = nil
    @State private var selectedHistoryID: String? = nil
    @State private var isConfirmingClearHistory: Bool = false
    @State private var isPresentingPullImage: Bool = false
    @State private var isShowingImageInspect: Bool = false
    @State private var isShowingVolumeInspect: Bool = false
    @State private var isConfirmingDeleteImage: Bool = false
    @State private var isConfirmingPruneImages: Bool = false
    @State private var selectedImageIDs: Set<String> = []
    @State private var imageSort: ImageSort = .reference
    @State private var groupImagesByRepo: Bool = false

    @State private var searchText: String = ""

    enum ImageSort: String, CaseIterable {
        case reference, size, mediaType
        var label: String {
            switch self {
            case .reference: return "Reference"
            case .size: return "Size"
            case .mediaType: return "Media type"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            rootContent

            ErrorBanner(message: Binding(get: { vm.errorMessage }, set: { vm.errorMessage = $0 }))
                .animation(.easeInOut(duration: 0.2), value: vm.errorMessage)
        }
        .onChange(of: sidebarSelection) { _, _ in
            // Tab change clears the previous section's selection so the detail
            // pane doesn't show a stale item the next time the user comes back.
            selectedContainerIDs.removeAll()
            selectedContainerID = nil
            selectedImageIDs.removeAll()
            selectedImageID = nil
            selectedVolumeIDs.removeAll()
            selectedVolumeID = nil
            selectedHistoryID = nil
            searchText = ""
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if vm.systemStatus == "Unknown" {
            SystemLoadingView()
        } else if !vm.isSystemRunning {
            SystemStoppedView()
        } else {
            NavigationSplitView {
                sidebar
            } content: {
                contentList
            } detail: {
                detail
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Resources") {
                Label("Containers", systemImage: "shippingbox").tag(SidebarSection.containers)
                Label("Images", systemImage: "photo.on.rectangle").tag(SidebarSection.images)
                Label("Volumes", systemImage: "externaldrive").tag(SidebarSection.volumes)
            }
            Section("History") {
                HStack {
                    Label("Recently Deleted", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    let deletedCount = vm.history.filter(\.isDeleted).count
                    if deletedCount > 0 {
                        Text("\(deletedCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarSection.recentlyDeleted)
            }
        }
        .navigationTitle("Container UI")
    }

    // MARK: - Content list

    @ViewBuilder
    private var contentList: some View {
        switch sidebarSelection {
        case .containers, .none:
            containersList
        case .images:
            imagesList
        case .volumes:
            volumesList
        case .recentlyDeleted:
            recentlyDeletedList
        }
    }

    private var filteredContainers: [ContainerModel] {
        guard !searchText.isEmpty else { return vm.containers }
        let needle = searchText.lowercased()
        return vm.containers.filter {
            $0.id.lowercased().contains(needle) ||
            $0.image.lowercased().contains(needle) ||
            ($0.addr ?? "").lowercased().contains(needle)
        }
    }

    private var filteredImages: [ImageModel] {
        let needle = searchText.lowercased()
        let base = searchText.isEmpty
            ? vm.images
            : vm.images.filter { $0.id.lowercased().contains(needle) }
        switch imageSort {
        case .reference:
            return base.sorted { $0.id < $1.id }
        case .size:
            return base.sorted { (parseBytes($0.size) ?? 0) > (parseBytes($1.size) ?? 0) }
        case .mediaType:
            return base.sorted { ($0.mediaType ?? "") < ($1.mediaType ?? "") }
        }
    }

    private var groupedImages: [(repository: String, images: [ImageModel])] {
        let grouped = Dictionary(grouping: filteredImages) { image -> String in
            // Strip tag — e.g. "docker.io/library/redis:latest" → "docker.io/library/redis"
            if let colon = image.id.lastIndex(of: ":") {
                let afterSlash = image.id.range(of: "/", options: .backwards)?.lowerBound
                if let afterSlash, colon > afterSlash {
                    return String(image.id[..<colon])
                }
            }
            return image.id
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.0 < $1.0 }
    }

    /// Best-effort byte parse for sorting. `ByteCountFormatter` output isn't
    /// reversible, so we accept "1.2 KB", "9 KB", "306 bytes" etc.
    private func parseBytes(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1).map { String($0) }
        guard let first = parts.first, let value = Double(first.replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        let unit = parts.count > 1 ? parts[1].lowercased() : "b"
        let factor: Double
        switch unit {
        case "b", "bytes", "byte": factor = 1
        case "kb": factor = 1_000
        case "mb": factor = 1_000_000
        case "gb": factor = 1_000_000_000
        case "tb": factor = 1_000_000_000_000
        default: factor = 1
        }
        return Int64(value * factor)
    }

    private var filteredVolumes: [VolumeModel] {
        guard !searchText.isEmpty else { return vm.volumes }
        let needle = searchText.lowercased()
        return vm.volumes.filter {
            $0.id.lowercased().contains(needle) ||
            ($0.mountpoint ?? "").lowercased().contains(needle)
        }
    }

    private var containersList: some View {
        List(selection: $selectedContainerIDs) {
            ForEach(filteredContainers) { container in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(container.id).font(.headline).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(container.image).font(.caption).foregroundColor(.secondary)
                            if let os = container.os, let arch = container.arch {
                                Text("\(os)/\(arch)").font(.caption).foregroundColor(.secondary)
                            }
                            if let addr = container.addr { Text(addr).font(.caption2).foregroundColor(.secondary) }
                            if !container.ports.isEmpty {
                                Text(container.ports.map(\.displayString).joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Text(container.state)
                        .font(.subheadline)
                        .foregroundColor(container.state.lowercased() == "running" ? .green : .red)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }
                .tag(container.id)
                .contextMenu {
                    Button("Start") { applyContainerAction(container.id) { id in await vm.startContainer(id) } }
                    Button("Stop") { applyContainerAction(container.id) { id in await vm.stopContainer(id) } }
                    Button("Restart") { applyContainerAction(container.id) { id in await vm.restartContainer(id) } }
                    Divider()
                    Button("Clone…") {
                        Task {
                            if let opts = await vm.cloneOptions(for: container.id) {
                                cloneOptions = opts
                                isPresentingCloneContainer = true
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        if !selectedContainerIDs.contains(container.id) {
                            selectedContainerIDs = [container.id]
                        }
                        isConfirmingDeleteContainer = true
                    } label: {
                        Text(selectedContainerIDs.count > 1 && selectedContainerIDs.contains(container.id)
                             ? "Delete \(selectedContainerIDs.count) containers"
                             : "Delete")
                    }
                }
            }
        }
        .onChange(of: selectedContainerIDs) { _, newValue in
            selectedContainerID = newValue.count == 1 ? newValue.first : nil
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search containers")
        .navigationTitle("Containers")
        .toolbar {
            Button {
                isPresentingAddContainer = true
            } label: {
                Label("Add Container", systemImage: "plus")
            }
            .help("Create a new container")
            Button(role: .destructive) {
                isConfirmingDeleteContainer = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedContainerIDs.isEmpty)
            .help(selectedContainerIDs.count > 1
                  ? "Delete \(selectedContainerIDs.count) containers"
                  : "Delete selected container")
        }
        .sheet(isPresented: $isPresentingAddContainer) {
            ContainerCreateView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $isPresentingCloneContainer) {
            if let opts = cloneOptions {
                ContainerCreateView(title: "Clone Container", prefilled: opts)
                    .environmentObject(vm)
            }
        }
        .confirmationDialog(
            deleteContainersDialogTitle,
            isPresented: $isConfirmingDeleteContainer,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = Array(selectedContainerIDs)
                Task {
                    for id in ids { await vm.deleteContainer(id) }
                    selectedContainerIDs.removeAll()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var deleteContainersDialogTitle: String {
        switch selectedContainerIDs.count {
        case 0: return "Delete container?"
        case 1: return "Delete container '\(selectedContainerIDs.first!)'?"
        default: return "Delete \(selectedContainerIDs.count) containers?"
        }
    }

    /// Run a single-target action against all currently-selected containers if the
    /// invocation came from a context-menu item on a row that's part of the
    /// multi-selection. Otherwise act on just the invoking row.
    private func applyContainerAction(_ invokingId: String, _ action: @escaping (String) async -> Void) {
        let ids: [String]
        if selectedContainerIDs.contains(invokingId), selectedContainerIDs.count > 1 {
            ids = Array(selectedContainerIDs)
        } else {
            ids = [invokingId]
        }
        Task {
            for id in ids { await action(id) }
        }
    }

    private var imagesList: some View {
        List(selection: $selectedImageIDs) {
            if groupImagesByRepo {
                ForEach(groupedImages, id: \.repository) { group in
                    Section(group.repository) {
                        ForEach(group.images) { imageRow($0) }
                    }
                }
            } else {
                ForEach(filteredImages) { imageRow($0) }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search images")
        .navigationTitle("Images")
        .onChange(of: selectedImageIDs) { _, newValue in
            if newValue.count == 1, let first = newValue.first {
                selectedImageID = first
            } else if newValue.isEmpty {
                selectedImageID = nil
            }
        }
        .toolbar {
            Button {
                isPresentingPullImage = true
            } label: {
                Label("Pull", systemImage: "square.and.arrow.down")
            }
            .help("Pull an image from a registry")
            Button {
                loadImageFromArchive()
            } label: {
                Label("Load", systemImage: "tray.and.arrow.down")
            }
            .help("Load an image from an OCI tar archive")
            Button {
                isConfirmingPruneImages = true
            } label: {
                Label("Prune", systemImage: "wand.and.sparkles")
            }
            .help("Remove unreferenced and dangling images")
            Button(role: .destructive) {
                isConfirmingDeleteImage = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedImageIDs.isEmpty)
            .help(selectedImageIDs.count > 1
                  ? "Delete \(selectedImageIDs.count) images"
                  : "Delete selected image")
            Menu {
                Picker("Sort by", selection: $imageSort) {
                    ForEach(ImageSort.allCases, id: \.self) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
                Divider()
                Toggle("Group by repository", isOn: $groupImagesByRepo)
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
            .help("Sort and grouping options")
        }
        .sheet(isPresented: $isPresentingPullImage) {
            ImagePullView()
                .environmentObject(vm)
        }
        .confirmationDialog(
            "Prune dangling images?",
            isPresented: $isConfirmingPruneImages,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                Task { await vm.pruneImages() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unreferenced and dangling images will be removed.")
        }
        .sheet(isPresented: $isShowingImageInspect) {
            if let id = selectedImageID {
                InspectSheetView(title: "Image \(id)") {
                    await vm.inspectImage(id)
                }
            }
        }
        .confirmationDialog(
            deleteImagesDialogTitle,
            isPresented: $isConfirmingDeleteImage,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = Array(selectedImageIDs)
                Task {
                    for id in ids {
                        await vm.deleteImage(reference: id)
                    }
                    selectedImageIDs.removeAll()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var deleteImagesDialogTitle: String {
        switch selectedImageIDs.count {
        case 0: return "Delete image?"
        case 1: return "Delete image '\(selectedImageIDs.first!)'?"
        default: return "Delete \(selectedImageIDs.count) images?"
        }
    }

    @ViewBuilder
    private func imageRow(_ image: ImageModel) -> some View {
        HStack {
            Image(systemName: "photo.on.rectangle")
            VStack(alignment: .leading) {
                Text(image.id).lineLimit(1)
                HStack(spacing: 8) {
                    if let size = image.size {
                        Text(size).font(.caption).foregroundColor(.secondary)
                    }
                    if let mediaType = image.mediaType, mediaType.contains("index") {
                        Text("multi-arch")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue.opacity(0.18))
                            )
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .tag(image.id)
        .contextMenu {
            Button("Inspect") { isShowingImageInspect = true }
            Divider()
            Button(role: .destructive) {
                if !selectedImageIDs.contains(image.id) {
                    selectedImageIDs = [image.id]
                }
                isConfirmingDeleteImage = true
            } label: {
                Text(selectedImageIDs.count > 1 && selectedImageIDs.contains(image.id)
                     ? "Delete \(selectedImageIDs.count) images"
                     : "Delete")
            }
        }
    }

    private var volumesList: some View {
        List(selection: $selectedVolumeIDs) {
            ForEach(filteredVolumes) { volume in
                HStack {
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading) {
                        Text(volume.id).lineLimit(1)
                        if let mp = volume.mountpoint { Text(mp).font(.caption).foregroundColor(.secondary) }
                    }
                }
                .tag(volume.id)
                .contextMenu {
                    Button("Inspect") { isShowingVolumeInspect = true }
                    Divider()
                    Button(role: .destructive) {
                        if !selectedVolumeIDs.contains(volume.id) {
                            selectedVolumeIDs = [volume.id]
                        }
                        isConfirmingDeleteVolume = true
                    } label: {
                        Text(selectedVolumeIDs.count > 1 && selectedVolumeIDs.contains(volume.id)
                             ? "Delete \(selectedVolumeIDs.count) volumes"
                             : "Delete")
                    }
                }
            }
        }
        .onChange(of: selectedVolumeIDs) { _, newValue in
            selectedVolumeID = newValue.count == 1 ? newValue.first : nil
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search volumes")
        .navigationTitle("Volumes")
        .toolbar {
            Button {
                isPresentingAddVolume = true
            } label: {
                Label("Add Volume", systemImage: "plus")
            }
            .help("Create a new volume")
            Button(role: .destructive) {
                isConfirmingDeleteVolume = true
            } label: {
                Label("Delete Volume", systemImage: "trash")
            }
            .disabled(selectedVolumeIDs.isEmpty)
            .help(selectedVolumeIDs.count > 1
                  ? "Delete \(selectedVolumeIDs.count) volumes"
                  : "Delete selected volume")
        }
        .sheet(isPresented: $isPresentingAddVolume) {
            VolumeCreateView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $isShowingVolumeInspect) {
            if let id = selectedVolumeID {
                InspectSheetView(title: "Volume \(id)") {
                    await vm.inspectVolume(id)
                }
            }
        }
        .confirmationDialog(
            deleteVolumesDialogTitle,
            isPresented: $isConfirmingDeleteVolume,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = Array(selectedVolumeIDs)
                Task {
                    for id in ids { await vm.deleteVolume(name: id) }
                    selectedVolumeIDs.removeAll()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var deleteVolumesDialogTitle: String {
        switch selectedVolumeIDs.count {
        case 0: return "Delete volume?"
        case 1: return "Delete volume '\(selectedVolumeIDs.first!)'?"
        default: return "Delete \(selectedVolumeIDs.count) volumes?"
        }
    }

    private func loadImageFromArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await vm.loadImage(from: url.path) }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection {
        case .containers, .none:
            if selectedContainerIDs.count > 1 {
                ContainerBulkSelectionView(ids: selectedContainerIDs)
            } else if let id = selectedContainerID, let container = vm.containers.first(where: { $0.id == id }) {
                ContainerDetailView(container: container, onSelectVolume: { volName in
                    sidebarSelection = .volumes
                    selectedVolumeID = volName
                })
            } else {
                Text("Select a container to see details").foregroundColor(.secondary)
            }
        case .images:
            if let imgID = selectedImageID {
                ImageDetailView(imageID: imgID, onSelectContainer: { cid in
                    sidebarSelection = .containers
                    selectedContainerID = cid
                })
            } else {
                Text("Select an image to see details").foregroundColor(.secondary)
            }
        case .volumes:
            if let volID = selectedVolumeID, let volume = vm.volumes.first(where: { $0.id == volID }) {
                VolumeDetailView(
                    volume: volume,
                    onSelectContainer: { cid in
                        sidebarSelection = .containers
                        selectedContainerID = cid
                    },
                    onMountIntoNewContainer: {
                        sidebarSelection = .containers
                        isPresentingAddContainer = true
                    }
                )
                .environmentObject(vm)
            } else {
                Text("Select a volume to see details").foregroundColor(.secondary)
            }
        case .recentlyDeleted:
            if let id = selectedHistoryID, let entry = vm.history.first(where: { $0.id == id }) {
                RecentlyDeletedDetailView(
                    entry: entry,
                    onRecreate: { startRecreate(from: entry) },
                    onForget: {
                        Task { await vm.forgetHistoryEntry(entry.id) }
                        selectedHistoryID = nil
                    }
                )
            } else {
                Text("Select an entry to see details").foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Recently deleted

    private var deletedHistory: [ContainerHistoryEntry] {
        vm.history.filter(\.isDeleted)
    }

    private var recentlyDeletedList: some View {
        Group {
            if deletedHistory.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No deleted containers recorded yet.")
                        .foregroundStyle(.secondary)
                    Text("Containers seen by the app while running are remembered here when they disappear.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $selectedHistoryID) {
                    ForEach(deletedHistory) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.id).font(.headline).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(entry.image).font(.caption).foregroundColor(.secondary)
                                    if let deletedAt = entry.deletedAt {
                                        Text("deleted \(deletedAt.formatted(.relative(presentation: .named)))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("Recreate") { startRecreate(from: entry) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .tag(entry.id)
                        .contextMenu {
                            Button("Recreate…") { startRecreate(from: entry) }
                            Divider()
                            Button(role: .destructive) {
                                Task { await vm.forgetHistoryEntry(entry.id) }
                            } label: {
                                Text("Forget")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            Button(role: .destructive) {
                isConfirmingClearHistory = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(deletedHistory.isEmpty)
            .help("Forget all recently-deleted entries")
        }
        .sheet(isPresented: $isPresentingRecreate) {
            if let opts = recreateOptions {
                ContainerCreateView(title: "Recreate Container", prefilled: opts)
                    .environmentObject(vm)
            }
        }
        .confirmationDialog(
            "Forget all recently-deleted entries?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await vm.clearDeletedHistory() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This only removes the records from this app — no containers are affected.")
        }
    }

    private func startRecreate(from entry: ContainerHistoryEntry) {
        recreateOptions = vm.recreateOptions(from: entry)
        isPresentingRecreate = true
    }
}

// MARK: - Recently deleted detail

private struct RecentlyDeletedDetailView: View {
    let entry: ContainerHistoryEntry
    let onRecreate: () -> Void
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.id).font(.title2).bold()
                    Text(entry.image).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recreate", action: onRecreate)
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive, action: onForget) {
                    Label("Forget", systemImage: "trash")
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if let deletedAt = entry.deletedAt {
                    GridRow {
                        Text("Deleted").foregroundStyle(.secondary)
                        Text(deletedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
                GridRow {
                    Text("First seen").foregroundStyle(.secondary)
                    Text(entry.firstSeen.formatted(date: .abbreviated, time: .standard))
                }
                GridRow {
                    Text("Last seen").foregroundStyle(.secondary)
                    Text(entry.lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                if !entry.options.publishPorts.isEmpty {
                    GridRow {
                        Text("Ports").foregroundStyle(.secondary)
                        Text(entry.options.publishPorts.joined(separator: ", "))
                    }
                }
                if !entry.options.env.isEmpty {
                    GridRow {
                        Text("Env").foregroundStyle(.secondary)
                        Text("\(entry.options.env.count) variable\(entry.options.env.count == 1 ? "" : "s")")
                    }
                }
                if !entry.options.volumeMappings.isEmpty {
                    GridRow {
                        Text("Volumes").foregroundStyle(.secondary)
                        Text(entry.options.volumeMappings.keys.sorted().joined(separator: ", "))
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Previews

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ContainerViewModel())
            .frame(width: 1000, height: 500)
    }
}
#endif
