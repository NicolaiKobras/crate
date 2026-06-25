import SwiftUI
import AppKit

struct VolumeDetailView: View {
    let volume: VolumeModel
    var onSelectContainer: (String) -> Void = { _ in }
    var onMountIntoNewContainer: (() -> Void)? = nil
    @EnvironmentObject private var vm: ContainerViewModel
    @State private var isShowingInspect = false

    private func containersUsingVolume() -> [ContainerModel] {
        let volName = volume.id
        let volSourcePath = (volume.source?.removingPercentEncoding ?? volume.source) ?? volume.mountpoint
        return vm.containers.filter { c in
            c.mounts.contains { m in
                if let name = m.volumeName, !name.isEmpty, name == volName { return true }
                if let src = m.source, let vsrc = volSourcePath, !vsrc.isEmpty {
                    let lhs = src.removingPercentEncoding ?? src
                    return lhs == vsrc
                }
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        HStack { Text("Name:"); Text(volume.id).bold().textSelection(.enabled) }
                        if let mp = volume.mountpoint, !mp.isEmpty {
                            HStack { Text("Mountpoint:"); Text(mp).bold().textSelection(.enabled) }
                        }
                        if let src = volume.source { HStack { Text("Source:"); Text(src).bold().textSelection(.enabled) } }
                        if let drv = volume.driver { HStack { Text("Driver:"); Text(drv).bold() } }
                        if let fmt = volume.format { HStack { Text("Format:"); Text(fmt).bold() } }
                        if let ts = volume.createdAt {
                            let date = Date(timeIntervalSince1970: ts)
                            HStack { Text("Created:"); Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)).bold() }
                        }
                    }

                    if let labels = volume.labels, !labels.isEmpty {
                        Divider().padding(.vertical, 6)
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

                    if let opts = volume.options, !opts.isEmpty {
                        Divider().padding(.vertical, 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Options").font(.headline)
                            ForEach(opts.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(k).foregroundStyle(.secondary).font(.system(.caption, design: .monospaced))
                                    Text("=").foregroundStyle(.secondary).font(.caption)
                                    Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }
                    }

                    Divider().padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Used by Containers").font(.headline)
                        let used = containersUsingVolume()
                        if used.isEmpty {
                            Text("No containers referencing this volume found.").foregroundColor(.secondary)
                        } else {
                            ForEach(used) { c in
                                Button(action: { onSelectContainer(c.id) }) {
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

                    Spacer(minLength: 24)
                }
                .padding(15)
            }
        }
        .navigationTitle(volume.id)
        .navigationSubtitle(navigationSubtitle)
        .sheet(isPresented: $isShowingInspect) {
            InspectSheetView(title: "Volume \(volume.id)") {
                await vm.inspectVolume(volume.id)
            }
        }
    }

    private var navigationSubtitle: String {
        let driver = volume.driver ?? "local"
        if let fmt = volume.format, !fmt.isEmpty {
            return "\(driver) · \(fmt)"
        }
        return driver
    }

    private var revealPath: String? {
        if let src = volume.source, !src.isEmpty { return src.removingPercentEncoding ?? src }
        if let mp = volume.mountpoint, !mp.isEmpty { return mp.removingPercentEncoding ?? mp }
        return nil
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            if let path = revealPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal volume on disk")
            }

            Button {
                vm.pendingCreateContainerVolume = volume.id
                onMountIntoNewContainer?()
            } label: {
                Label("Mount in New Container", systemImage: "plus.rectangle.on.folder")
            }
            .help("Create a new container with this volume attached")

            Button {
                isShowingInspect = true
            } label: {
                Label("Inspect", systemImage: "doc.text.magnifyingglass")
            }
            .help("Show full volume configuration")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}
