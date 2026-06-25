import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContainerDetailView: View {
    let container: ContainerModel
    var onSelectVolume: (String) -> Void = { _ in }
    @EnvironmentObject private var vm: ContainerViewModel

    @State private var isShowingInspect = false
    @State private var isShowingClone = false
    @State private var cloneOptions: ContainerCreateOptions? = nil
    @State private var isLoadingClone = false
    @State private var cloneTask: Task<Void, Never>? = nil
    @State private var inflight: LifecycleAction? = nil

    enum LifecycleAction { case start, stop, restart, kill }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar

            VStack(alignment: .leading, spacing: 12) {
                details

                if !container.ports.isEmpty {
                    Divider().padding(.vertical, 8)
                    portsSection
                }

                Divider().padding(.vertical, 8)
                mountsSection

                Divider().padding(.vertical, 8)
                ContainerLogsView(containerId: container.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(15)
        }
        .navigationTitle(container.id)
        .navigationSubtitle("\(container.image) · \(container.state)")
        .sheet(isPresented: $isShowingInspect) {
            InspectSheetView(title: "Container \(container.id)") {
                await vm.inspectContainer(container.id)
            }
        }
        .sheet(isPresented: $isShowingClone) {
            if let opts = cloneOptions {
                ContainerCreateView(title: "Clone Container", prefilled: opts)
                    .environmentObject(vm)
            }
        }
        .onChange(of: container.id) { _, _ in
            // Switching to a different container while a clone inspect is in
            // flight: cancel it, otherwise the late result would set state for
            // the previous container.
            cloneTask?.cancel()
            cloneTask = nil
            isLoadingClone = false
            cloneOptions = nil
        }
        .onDisappear {
            cloneTask?.cancel()
            cloneTask = nil
        }
    }

    // MARK: - Inline action bar

    private var lifecycleBusy: Bool { inflight != nil }

    private func runLifecycle(_ action: LifecycleAction, _ body: @escaping () async -> Void) {
        guard inflight == nil else { return }
        inflight = action
        Task {
            await body()
            inflight = nil
        }
    }

    @ViewBuilder
    private func lifecycleLabel(_ activeWhen: LifecycleAction,
                                pending title: String,
                                idle: String,
                                systemImage: String) -> some View {
        if inflight == activeWhen {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(title)
            }
        } else {
            Label(idle, systemImage: systemImage)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button {
                runLifecycle(.start) { await vm.startContainer(container.id) }
            } label: {
                lifecycleLabel(.start, pending: "Starting…", idle: "Start", systemImage: "play.fill")
            }
            .disabled(container.running || lifecycleBusy)
            .help("Start container")

            Button {
                runLifecycle(.stop) { await vm.stopContainer(container.id) }
            } label: {
                lifecycleLabel(.stop, pending: "Stopping…", idle: "Stop", systemImage: "stop.fill")
            }
            .disabled(!container.running || lifecycleBusy)
            .help("Stop container")

            Button {
                runLifecycle(.restart) { await vm.restartContainer(container.id) }
            } label: {
                lifecycleLabel(.restart, pending: "Restarting…", idle: "Restart", systemImage: "arrow.trianglehead.counterclockwise")
            }
            .disabled(lifecycleBusy)
            .help("Restart container")

            Menu {
                ForEach(["TERM", "INT", "HUP", "KILL", "QUIT", "USR1", "USR2"], id: \.self) { sig in
                    Button("SIG\(sig)") {
                        runLifecycle(.kill) { await vm.killContainer(container.id, signal: sig) }
                    }
                }
            } label: {
                lifecycleLabel(.kill, pending: "Sending…", idle: "Kill", systemImage: "bolt")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(lifecycleBusy)
            .help("Send signal to the container")

            Divider().frame(height: 18).padding(.horizontal, 2)

            Button {
                isShowingInspect = true
            } label: {
                Label("Inspect", systemImage: "doc.text.magnifyingglass")
            }
            .help("Show full container configuration")

            Menu {
                Button("/bin/sh")   { launchNativeShell("/bin/sh") }
                Button("/bin/bash") { launchNativeShell("/bin/bash") }
                Button("/bin/zsh")  { launchNativeShell("/bin/zsh") }
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!container.running)
            .help("Open interactive shell in the default terminal")

            Button {
                beginClone()
            } label: {
                if isLoadingClone {
                    Label("Cloning…", systemImage: "hourglass")
                } else {
                    Label("Clone", systemImage: "doc.on.doc")
                }
            }
            .disabled(isLoadingClone)
            .help("Clone container with its configuration")

            Spacer()

            Button(role: .destructive) {
                Task { await vm.deleteContainer(container.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete container")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func launchNativeShell(_ shell: String) {
        if let error = NativeTerminal.openShell(containerId: container.id, shell: shell) {
            vm.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to open terminal: \(error)"
        }
    }

    private func beginClone() {
        guard !isLoadingClone else { return }
        // Cancel any previous attempt so we never end up with two in-flight
        // inspects competing to set state.
        cloneTask?.cancel()
        isLoadingClone = true
        let id = container.id
        cloneTask = Task {
            let opts = await vm.cloneOptions(for: id)
            // If the view was swapped (new container selected) or replaced
            // entirely while we were awaiting, drop the result.
            if Task.isCancelled || id != container.id { return }
            isLoadingClone = false
            if let opts {
                cloneOptions = opts
                isShowingClone = true
            }
        }
    }

    private var details: some View {
        Group {
            HStack { Text("Image:"); Text(container.image).bold() }
            if let os = container.os, let arch = container.arch {
                HStack { Text("Platform:"); Text("\(os)/\(arch)").bold() }
            }
            HStack {
                Text("State:")
                Text(container.state)
                    .bold()
                    .foregroundColor(container.state.lowercased() == "running" ? .green : .red)
            }
            if let addr = container.addr {
                HStack {
                    Text("Address:")
                    Text(addr).bold().textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(addr, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy address")
                }
            }
        }
    }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ports").font(.headline)
            ForEach(container.ports) { p in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(p.displayString).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p.displayString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy port mapping")
                }
            }
        }
    }

    private var mountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volumes").font(.headline)
            if container.mounts.isEmpty {
                Text("No volumes mounted.").foregroundColor(.secondary)
            } else {
                ForEach(container.mounts) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = m.volumeName, !name.isEmpty {
                                Button(action: { onSelectVolume(name) }) {
                                    Text(name).bold().underline()
                                }
                                .buttonStyle(.plain)
                                .help("Show volume details")
                            } else if let src = m.source {
                                Text(src).bold().textSelection(.enabled)
                            }
                            if let dest = m.destination { Text("→ \(dest)").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Logs panel

private struct ContainerLogsView: View {
    let containerId: String
    @EnvironmentObject private var vm: ContainerViewModel
    @State private var follow: Bool = true
    @State private var tail: Int = 200
    @State private var autoScroll: Bool = true
    @State private var showLineNumbers: Bool = true
    @State private var wrapLines: Bool = true

    private let terminalBackground = Color(red: 0.10, green: 0.11, blue: 0.13)
    private let terminalForeground = Color(red: 0.94, green: 0.95, blue: 0.96)
    private let gutterForeground = Color.white.opacity(0.65)
    private let gutterBackground = Color.white.opacity(0.05)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            terminal
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        .onAppear {
            Task { await reload(follow: follow) }
        }
        .onDisappear {
            vm.stopLogs()
        }
        .onChange(of: containerId) { _, _ in
            Task { await reload(follow: follow) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            statusBadge

            Text("Console")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(terminalForeground)

            Spacer()

            Toggle(isOn: $follow) { Text("Follow").foregroundStyle(.white) }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .onChange(of: follow) { _, newValue in
                    Task { await reload(follow: newValue) }
                }

            Toggle(isOn: $autoScroll) { Text("Auto-scroll").foregroundStyle(.white) }
                .toggleStyle(.switch)
                .controlSize(.small)

            Menu {
                Toggle("Line numbers", isOn: $showLineNumbers)
                Toggle("Wrap lines", isOn: $wrapLines)
                Divider()
                Picker("Tail", selection: $tail) {
                    ForEach([50, 100, 200, 500, 1000, 2000, 5000], id: \.self) { v in
                        Text("\(v) lines").tag(v)
                    }
                }
                .onChange(of: tail) { _, _ in
                    Task { await reload(follow: follow) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").tint(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("View options")

            terminalButton("trash", help: "Clear") { vm.logs.removeAll() }
            terminalButton("doc.on.doc", help: "Copy all") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.logs.map(\.text).joined(separator: "\n"), forType: .string)
            }
            terminalButton("square.and.arrow.down", help: "Save to file…") {
                saveLogsToFile()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.16, green: 0.17, blue: 0.20))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(height: 1)
        }
    }

    private var statusBadge: some View {
        let isLive = follow
        return HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: isLive ? Color.green.opacity(0.6) : .clear, radius: 4)
            Text(isLive ? "LIVE" : "STATIC")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(isLive ? Color.green : Color.gray)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }

    private func terminalButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .foregroundStyle(terminalForeground.opacity(0.85))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .help(help)
    }

    // MARK: Terminal surface

    private var terminal: some View {
        ZStack(alignment: .topLeading) {
            terminalBackground

            if vm.logs.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, wrapLines ? [] : .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(vm.logs.enumerated()), id: \.element.id) { idx, line in
                                logRow(index: idx, line: line.text)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: vm.logs.count) { _, _ in
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                    .onChange(of: containerId) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            scrollToBottom(proxy: proxy, animated: false)
                        }
                    }
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard autoScroll, let last = vm.logs.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(follow ? "Waiting for output…" : "No logs")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func logRow(index: Int, line: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if showLineNumbers {
                Text(String(format: "%4d", index + 1))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(gutterForeground)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.vertical, 1)
                    .background(gutterBackground)
            }
            Text(line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colorForLine(line))
                .textSelection(.enabled)
                .lineLimit(wrapLines ? nil : 1)
                .fixedSize(horizontal: !wrapLines, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 1)
                .padding(.trailing, 8)
        }
    }

    private func colorForLine(_ line: String) -> Color {
        // Match at word boundaries so substrings like "warning" inside a normal
        // sentence don't paint the whole line amber.
        if Self.errorRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil {
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
        if Self.warnRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil {
            return Color(red: 1.0, green: 0.78, blue: 0.32)
        }
        if Self.debugRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil {
            return Color.white.opacity(0.65)
        }
        return terminalForeground
    }

    // Compiled once and reused. `try?` so a future typo in the pattern
    // disables colorization instead of crashing the app on first use.
    private static let errorRegex = (try? NSRegularExpression(
        pattern: #"(?i)\b(error|fatal|panic|err)\b"#
    )) ?? NSRegularExpression()
    private static let warnRegex = (try? NSRegularExpression(
        pattern: #"(?i)\b(warn|warning)\b"#
    )) ?? NSRegularExpression()
    private static let debugRegex = (try? NSRegularExpression(
        pattern: #"(?i)\b(debug|trace|dbg|trc)\b"#
    )) ?? NSRegularExpression()

    private func reload(follow: Bool) async {
        vm.stopLogs()
        if follow {
            await vm.startLogs(for: containerId)
        } else {
            vm.logs.removeAll()
            if let snapshot = await vm.fetchLogs(for: containerId, tail: tail) {
                vm.replaceLogs(with: snapshot.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
        }
    }

    private func saveLogsToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(containerId)-logs.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? vm.logs.map(\.text).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
