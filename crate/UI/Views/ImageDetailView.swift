import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageDetailView: View {
    let imageID: String
    var onSelectContainer: (String) -> Void = { _ in }
    @EnvironmentObject private var vm: ContainerViewModel

    @State private var isShowingInspect = false
    @State private var isConfirmingDelete = false
    @State private var isShowingTag = false
    @State private var isShowingPush = false
    @State private var isShowingRunFromImage = false
    @State private var newTagTarget: String = ""
    @State private var pushPlatform: String = ""

    @State private var details: ImageInspect? = nil
    @State private var isLoadingDetails = false
    /// Monotonic id for in-flight inspect requests. When the user arrow-keys
    /// through the list quickly, multiple `loadDetails` tasks can race; we keep
    /// only the result whose generation matches the latest issued.
    @State private var inspectGeneration: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image = vm.images.first(where: { $0.id == imageID }), let size = image.size {
                        HStack { Text("Size:"); Text(size).bold() }
                    }

                    identitySection

                    if let details, !details.variants.isEmpty {
                        Divider().padding(.vertical, 6)
                        platformsSection(details)
                    }

                    if let details, !details.labels.isEmpty {
                        Divider().padding(.vertical, 6)
                        labelsSection(details.labels)
                    }

                    Divider().padding(.vertical, 6)
                    usedBySection

                    Spacer(minLength: 24)
                }
                .padding(15)
            }
        }
        .navigationTitle(imageID)
        .navigationSubtitle(navigationSubtitle)
        .task(id: imageID) { await loadDetails() }
        .sheet(isPresented: $isShowingInspect) {
            InspectSheetView(title: "Image \(imageID)") {
                await vm.inspectImage(imageID)
            }
        }
        .sheet(isPresented: $isShowingTag) { tagSheet }
        .sheet(isPresented: $isShowingPush) { pushSheet }
        .sheet(isPresented: $isShowingRunFromImage) {
            ContainerCreateView(
                title: "Run from image",
                prefilled: ContainerCreateOptions(name: "", image: imageID)
            )
            .environmentObject(vm)
        }
        .confirmationDialog(
            "Delete image '\(imageID)'?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await vm.deleteImage(reference: imageID) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Inline action bar

    private var navigationSubtitle: String {
        if let image = vm.images.first(where: { $0.id == imageID }), let size = image.size {
            if let media = details?.mediaType, media.contains("index") {
                return "\(size) · multi-arch"
            }
            return size
        }
        return ""
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button {
                isShowingRunFromImage = true
            } label: {
                Label("Run…", systemImage: "play.fill")
            }
            .help("Create and run a new container from this image")

            Divider().frame(height: 18).padding(.horizontal, 2)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(imageID, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy image reference to clipboard")

            Button {
                isShowingInspect = true
            } label: {
                Label("Inspect", systemImage: "doc.text.magnifyingglass")
            }
            .help("Show full image configuration JSON")

            Menu {
                Button("Tag…") { isShowingTag = true }
                Button("Push…") { isShowingPush = true }
                Button("Save to OCI archive…") { saveImageToArchive() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tag, push or save this image")

            Spacer()

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete image")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let digest = details?.digest {
                detailRow(label: "Digest", value: digest, monospaced: true, copyable: true)
            }
            if let mediaType = details?.mediaType {
                detailRow(label: "Media type", value: mediaType, monospaced: false)
            }
            if isLoadingDetails {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading details…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detailRow(label: String, value: String, monospaced: Bool, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
    }

    // MARK: - Platforms

    private func platformsSection(_ inspect: ImageInspect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Platforms").font(.headline)
                Text("(\(inspect.variants.count))").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(inspect.variants) { v in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(v.platformDisplay)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                    if let size = v.size {
                        Text(humanReadableBytes(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let created = v.created {
                        Text(formattedDate(created))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func humanReadableBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private func formattedDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) {
            return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
        }
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: iso) {
            return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
        }
        return iso
    }

    // MARK: - Labels

    private func labelsSection(_ labels: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labels").font(.headline)
            ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                HStack(alignment: .firstTextBaseline) {
                    Text(k).foregroundStyle(.secondary).font(.system(.caption, design: .monospaced))
                    Text("=").foregroundStyle(.secondary).font(.caption)
                    Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Used by

    private var usedBySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Used by Containers").font(.headline)
            let used = vm.containers.filter { $0.image == imageID }
            if used.isEmpty {
                Text("No containers reference this image.").foregroundColor(.secondary)
            } else {
                ForEach(used) { c in
                    Button {
                        onSelectContainer(c.id)
                    } label: {
                        HStack {
                            Image(systemName: "shippingbox")
                            Text(c.id).underline()
                            Text("(\(c.state))")
                                .foregroundStyle(c.state.lowercased() == "running" ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show container details")
                }
            }
        }
    }

    // MARK: - Sheets

    private var tagSheet: some View {
        VStack(alignment: .leading) {
            Text("Tag Image").font(.title3).bold()
            Form {
                Section("Source") { Text(imageID).textSelection(.enabled) }
                Section("New tag") {
                    TextField("registry/repo:tag", text: $newTagTarget)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isShowingTag = false; newTagTarget = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Tag") {
                    let target = newTagTarget.trimmingCharacters(in: .whitespaces)
                    isShowingTag = false
                    Task {
                        await vm.tagImage(source: imageID, target: target)
                        newTagTarget = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTagTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Create the new reference")
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 460, minHeight: 240)
        .padding()
    }

    private var pushSheet: some View {
        VStack(alignment: .leading) {
            Text("Push Image").font(.title3).bold()
            Form {
                Section("Reference") { Text(imageID).textSelection(.enabled) }
                Section("Platform (optional)") {
                    TextField("e.g. linux/arm64", text: $pushPlatform)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isShowingPush = false; pushPlatform = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Push") {
                    let platform = pushPlatform.trimmingCharacters(in: .whitespaces)
                    isShowingPush = false
                    Task {
                        await vm.pushImage(reference: imageID, platform: platform.isEmpty ? nil : platform)
                        pushPlatform = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .help("Push image to the registry")
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 460, minHeight: 240)
        .padding()
    }

    // MARK: - Helpers

    private func saveImageToArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.nameFieldStringValue = sanitizedFileName(from: imageID) + ".tar"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await vm.saveImage(reference: imageID, to: url.path, platform: nil) }
        }
    }

    private func sanitizedFileName(from ref: String) -> String {
        ref.replacingOccurrences(of: "/", with: "_")
           .replacingOccurrences(of: ":", with: "_")
    }

    @MainActor
    private func loadDetails() async {
        inspectGeneration += 1
        let generation = inspectGeneration
        isLoadingDetails = true
        // Clear stale data so the new image's section never briefly shows the
        // previous image's variants/labels while inspect is in flight.
        details = nil
        let result = await vm.inspectImageDetails(imageID)
        // Bail if another `loadDetails` started after us — newer wins.
        guard generation == inspectGeneration else { return }
        details = result
        isLoadingDetails = false
    }
}
