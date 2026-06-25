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
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "crate")
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
            (vm.isSystemRunning ? Image(systemName: "shippingbox") : Image(systemName: "stop"))
                .frame(width: 22, height: 22)
        }

        Window("Container", id: "crate") {
            ContentView()
                .environmentObject(vm)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
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
}
