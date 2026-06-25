import SwiftUI

struct ContainerCreateView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @Environment(\.dismiss) private var dismiss

    private let title: String

    // Basics
    @State private var name: String
    @State private var imageRef: String
    @State private var useCustomImage: Bool
    @State private var commandText: String

    // Environment
    @State private var envText: String           // newline-separated KEY=VALUE
    @State private var labelsText: String        // newline-separated key=value

    // Network
    @State private var portsText: String         // newline-separated host:container[/proto]
    @State private var dnsText: String           // comma-separated
    @State private var network: String

    // Resources
    @State private var cpus: String
    @State private var memory: String

    // Advanced
    @State private var workingDir: String
    @State private var user: String
    @State private var entrypoint: String
    @State private var osValue: String
    @State private var archValue: String
    @State private var platform: String
    @State private var removeOnExit: Bool
    @State private var interactive: Bool
    @State private var tty: Bool

    // Mounts
    @State private var selectedVolumeTargets: [String: String]
    @State private var isPresentingInlineCreateVolume: Bool = false

    @State private var validationError: String?

    init(title: String = "Create Container", prefilled: ContainerCreateOptions? = nil) {
        self.title = title
        let opts = prefilled
        _name = State(initialValue: opts?.name ?? "")
        _imageRef = State(initialValue: opts?.image ?? "")
        _useCustomImage = State(initialValue: opts != nil)
        _commandText = State(initialValue: opts?.command.joined(separator: " ") ?? "")
        _envText = State(initialValue: (opts?.env ?? []).joined(separator: "\n"))
        _labelsText = State(initialValue: (opts?.labels ?? []).joined(separator: "\n"))
        _portsText = State(initialValue: (opts?.publishPorts ?? []).joined(separator: "\n"))
        _dnsText = State(initialValue: (opts?.dns ?? []).joined(separator: ", "))
        _network = State(initialValue: opts?.network ?? "")
        _cpus = State(initialValue: opts?.cpus ?? "")
        _memory = State(initialValue: opts?.memory ?? "")
        _workingDir = State(initialValue: opts?.workingDir ?? "")
        _user = State(initialValue: opts?.user ?? "")
        _entrypoint = State(initialValue: opts?.entrypoint ?? "")
        _osValue = State(initialValue: opts?.osValue ?? "")
        _archValue = State(initialValue: opts?.archValue ?? "")
        _platform = State(initialValue: opts?.platform ?? "")
        _removeOnExit = State(initialValue: opts?.removeOnExit ?? false)
        _interactive = State(initialValue: opts?.interactive ?? false)
        _tty = State(initialValue: opts?.tty ?? false)
        _selectedVolumeTargets = State(initialValue: opts?.volumeMappings ?? [:])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2).bold()
                Spacer()
            }
            .padding()
            .onAppear {
                if let v = vm.pendingCreateContainerVolume, selectedVolumeTargets[v] == nil {
                    selectedVolumeTargets[v] = "/data/\(v)"
                }
                vm.pendingCreateContainerVolume = nil
            }

            Divider()

            TabView {
                basicsTab
                    .tabItem { Label("Basics", systemImage: "info.circle") }
                environmentTab
                    .tabItem { Label("Environment", systemImage: "list.bullet.rectangle") }
                networkTab
                    .tabItem { Label("Network", systemImage: "network") }
                resourcesTab
                    .tabItem { Label("Resources", systemImage: "cpu") }
                mountsTab
                    .tabItem { Label("Mounts", systemImage: "externaldrive") }
                advancedTab
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
            .padding()

            Divider()

            HStack {
                if let validationError {
                    Text(validationError).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let error = validate() {
                        validationError = error
                        return
                    }
                    Task {
                        await vm.createContainer(buildOptions())
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .help("Create the container with the configured options")
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || imageRef.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $isPresentingInlineCreateVolume) {
            VolumeCreateView { createdName in
                selectedVolumeTargets[createdName] = "/data/\(createdName)"
            }
            .environmentObject(vm)
        }
    }

    // MARK: Tabs

    private var basicsTab: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
            }
            Section("Image") {
                if useCustomImage {
                    TextField("docker.io/library/alpine:latest", text: $imageRef)
                } else {
                    Picker("Image", selection: $imageRef) {
                        Text("Select…").tag("")
                        ForEach(vm.images.map { $0.id }, id: \.self) { ref in
                            Text(ref).tag(ref)
                        }
                    }
                }
                Toggle("Enter custom image", isOn: $useCustomImage)
            }
            Section("Command (optional)") {
                TextField("Override CMD (space-separated)", text: $commandText)
            }
        }
    }

    private var environmentTab: some View {
        Form {
            Section("Environment variables (one per line: KEY=VALUE)") {
                TextEditor(text: $envText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
            }
            Section("Labels (one per line: key=value)") {
                TextEditor(text: $labelsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            }
        }
    }

    private var networkTab: some View {
        Form {
            Section("Published ports (one per line: [host-ip:]host-port:container-port[/proto])") {
                TextEditor(text: $portsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
            }
            Section("Network") {
                TextField("Network name (optional)", text: $network)
            }
            Section("DNS (comma-separated)") {
                TextField("8.8.8.8, 1.1.1.1", text: $dnsText)
            }
        }
    }

    private var resourcesTab: some View {
        Form {
            Section("CPU") {
                TextField("Number of CPUs (e.g. 2)", text: $cpus)
            }
            Section("Memory") {
                TextField("Memory (e.g. 512M, 2G)", text: $memory)
            }
        }
    }

    private var mountsTab: some View {
        Form {
            Section("Volumes") {
                Menu {
                    ForEach(vm.volumes.map { $0.id }, id: \.self) { v in
                        Button {
                            if selectedVolumeTargets.keys.contains(v) {
                                selectedVolumeTargets.removeValue(forKey: v)
                            } else {
                                selectedVolumeTargets[v] = "/data/\(v)"
                            }
                        } label: {
                            HStack {
                                Text(v)
                                Spacer()
                                if selectedVolumeTargets.keys.contains(v) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedVolumeTargets.isEmpty ? "Select Volumes…" : "Selected (\(selectedVolumeTargets.count))")
                        Spacer()
                        Image(systemName: "chevron.down").foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }

                if !selectedVolumeTargets.isEmpty {
                    ForEach(selectedVolumeTargets.keys.sorted(), id: \.self) { v in
                        HStack(alignment: .firstTextBaseline) {
                            Text(v).font(.subheadline)
                            TextField("/path/in/container", text: Binding(
                                get: { selectedVolumeTargets[v] ?? "" },
                                set: { selectedVolumeTargets[v] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                selectedVolumeTargets.removeValue(forKey: v)
                            } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove volume mapping")
                        }
                    }
                }

                Button {
                    isPresentingInlineCreateVolume = true
                } label: {
                    Label("Create New Volume", systemImage: "plus.circle")
                }
                .help("Create a new volume without leaving this dialog")
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Section("Process") {
                TextField("Working directory", text: $workingDir)
                TextField("User", text: $user)
                TextField("Entrypoint override", text: $entrypoint)
                Toggle("Remove container on exit (--rm)", isOn: $removeOnExit)
                Toggle("Interactive (-i)", isOn: $interactive)
                Toggle("Allocate TTY (-t)", isOn: $tty)
            }
            Section("Platform") {
                TextField("Platform (e.g. linux/arm64) — takes precedence over OS/Arch", text: $platform)
                TextField("OS (e.g. linux)", text: $osValue)
                TextField("Architecture (e.g. arm64)", text: $archValue)
            }
        }
    }

    // MARK: Build / validate

    private func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func validate() -> String? {
        let envs = splitLines(envText)
        for e in envs where !e.contains("=") {
            return "Environment variable `\(e)` must be in KEY=VALUE format."
        }
        let labels = splitLines(labelsText)
        for l in labels where !l.contains("=") {
            return "Label `\(l)` must be in key=value format."
        }
        let ports = splitLines(portsText)
        for p in ports where !p.contains(":") {
            return "Port `\(p)` must be in host:container[/proto] format."
        }
        return nil
    }

    private func buildOptions() -> ContainerCreateOptions {
        var options = ContainerCreateOptions(
            name: name.trimmingCharacters(in: .whitespaces),
            image: imageRef.trimmingCharacters(in: .whitespaces)
        )
        options.command = commandText
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        options.env = splitLines(envText)
        options.labels = splitLines(labelsText)
        options.publishPorts = splitLines(portsText)
        options.dns = dnsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        options.workingDir = workingDir.isEmpty ? nil : workingDir
        options.user = user.isEmpty ? nil : user
        options.entrypoint = entrypoint.isEmpty ? nil : entrypoint
        options.cpus = cpus.isEmpty ? nil : cpus
        options.memory = memory.isEmpty ? nil : memory
        options.osValue = osValue.isEmpty ? nil : osValue
        options.archValue = archValue.isEmpty ? nil : archValue
        options.platform = platform.isEmpty ? nil : platform
        options.network = network.isEmpty ? nil : network
        options.removeOnExit = removeOnExit
        options.interactive = interactive
        options.tty = tty
        options.volumeMappings = selectedVolumeTargets
        return options
    }
}
