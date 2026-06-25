import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @AppStorage("containerBinaryPath") private var containerBinaryPath: String = ""
    @AppStorage("pollingIntervalSeconds") private var pollingIntervalSeconds: Double = 5.0
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    @State private var detectedPath: String = ""
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            backendTab
                .tabItem { Label("Backend", systemImage: "terminal") }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            detectedPath = BinaryLocator.resolveContainerBinary(preferredPath: containerBinaryPath) ?? ""
        }
    }

    private var generalTab: some View {
        Form {
            Section("Polling") {
                HStack {
                    Slider(value: $pollingIntervalSeconds, in: 1...30, step: 1) {
                        Text("Interval")
                    }
                    Text("\(Int(pollingIntervalSeconds))s")
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
                .onChange(of: pollingIntervalSeconds) { _, newValue in
                    vm.startPolling(interval: newValue)
                }
                Text("How often the app refreshes container, image, and volume lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(enabled: newValue)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var backendTab: some View {
        Form {
            Section("`container` binary") {
                TextField("Auto-detect", text: $containerBinaryPath)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Browse…") { browseForBinary() }
                        .help("Choose the `container` executable manually")
                    Button("Clear") { containerBinaryPath = "" }
                        .help("Clear the override and fall back to auto-detection")
                    Spacer()
                    Button("Re-detect") {
                        detectedPath = BinaryLocator.resolveContainerBinary(preferredPath: containerBinaryPath) ?? ""
                    }
                    .help("Re-scan known locations for the `container` binary")
                }
                if detectedPath.isEmpty {
                    Label("No `container` binary found.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("Resolved: \(detectedPath)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Text("If empty, the app searches /opt/homebrew/bin, /usr/local/bin, /usr/bin, then $PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func browseForBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            containerBinaryPath = url.path
            detectedPath = BinaryLocator.resolveContainerBinary(preferredPath: url.path) ?? ""
        }
    }

    private func applyLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Failed to update Launch at Login: \(error.localizedDescription)"
        }
    }
}
