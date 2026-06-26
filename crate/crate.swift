import SwiftUI
import AppKit
import ServiceManagement

@MainActor
enum AppGlobals {
    static let viewModel = ContainerViewModel()
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let stored = UserDefaults.standard.double(forKey: "pollingIntervalSeconds")
        let interval = stored > 0 ? stored : 5
        AppGlobals.viewModel.startPolling(interval: interval)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: Notification.Name("AppWillTerminate"), object: nil)
    }
}

@main
struct ContainerStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var vm = AppGlobals.viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some Scene {
        MenuBarExtra {
            VStack {
                Text("\(vm.getRunningContainersAmount()) Containers running")
                Button("Open Container View") {
                    openMainWindow()
                }
                Divider()
                if vm.isSystemRunning {
                    Button("Stop System") { vm.stopSystem() }
                } else {
                    Button("Start System") { vm.startSystem() }
                }
                Divider()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(8)
            .frame(width: 200)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppWillTerminate"), object: nil)) { _ in
                vm.stopPolling()
            }
        } label: {
            let runningCount = vm.getRunningContainersAmount()
            HStack(spacing: 3) {
                Image(systemName: vm.isSystemRunning ? "shippingbox" : "stop")
                if vm.isSystemRunning && runningCount > 0 {
                    Text("\(runningCount)")
                }
            }
            .frame(height: 22)
        }

        Window("Container", id: "crate") {
            ContentView()
                .environmentObject(vm)
                .onAppear {
                    raiseMainWindow()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }

        Settings {
            SettingsView()
                .environmentObject(vm)
        }
    }

    /// Opens the main window from the menu bar and brings it to the front. The
    /// app runs as an accessory (no Dock icon) so we must switch to `.regular`
    /// and explicitly raise the window — otherwise it can open behind other apps.
    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "crate")
        // The window may not exist until the next runloop tick, so raise it then.
        DispatchQueue.main.async {
            raiseMainWindow()
        }
    }

    /// Brings the container window to the front. `orderFrontRegardless()` raises
    /// it even when the app isn't yet the active app, which a plain `activate()`
    /// won't reliably do for an accessory app.
    private func raiseMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { window in
            window.identifier?.rawValue.contains("crate") ?? false || window.title == "Container"
        } ?? NSApp.windows.first { $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
