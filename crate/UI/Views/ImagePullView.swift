import SwiftUI

struct ImagePullView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var reference: String = ""
    @State private var platform: String = ""
    @State private var output: [String] = []
    @State private var isPulling: Bool = false
    @State private var pullHandle: StreamHandle? = nil
    @State private var didFinish: Bool = false
    @State private var didFail: Bool = false
    @State private var exitCode: Int32 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pull Image").font(.title2).bold()
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Reference") {
                    TextField("docker.io/library/alpine:latest", text: $reference)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isPulling || didFinish)
                }
                Section("Optional") {
                    TextField("Platform (e.g. linux/arm64)", text: $platform)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isPulling || didFinish)
                }
            }
            .padding()

            if !output.isEmpty || isPulling {
                progressPanel
                    .frame(minHeight: 180, maxHeight: 260)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack {
                if isPulling {
                    ProgressView().controlSize(.small)
                    Text("Pulling…").foregroundStyle(.secondary)
                } else if didFail {
                    Label("Pull failed (exit \(exitCode))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else if didFinish {
                    Label("Pull complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                if isPulling {
                    Button("Stop", role: .destructive) {
                        pullHandle?.cancel()
                    }
                    .help("Cancel the running pull")
                } else if didFinish || didFail {
                    Button("Close", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Pull") { Task { await beginPull() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Pull this image from the registry")
                }
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 320)
        .onDisappear {
            pullHandle?.cancel()
        }
    }

    private var progressPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(output.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(red: 0.94, green: 0.95, blue: 0.96))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .id(idx)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: output.count) { _, _ in
                if let last = output.indices.last {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func beginPull() async {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let plat = platform.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }

        output.removeAll()
        didFinish = false
        didFail = false
        exitCode = 0
        isPulling = true

        guard let handle = await vm.streamPullImage(reference: ref,
                                                    platform: plat.isEmpty ? nil : plat,
                                                    onLine: { line in
            Task { @MainActor in
                output.append(line)
                if output.count > 5000 {
                    output.removeFirst(output.count - 5000)
                }
            }
        }) else {
            isPulling = false
            didFail = true
            exitCode = -1
            return
        }
        pullHandle = handle

        // Real wait — resumes the moment the child exits.
        let code = await handle.waitUntilDone()

        pullHandle = nil
        isPulling = false
        exitCode = code
        if code == 0 {
            didFinish = true
        } else {
            didFail = true
        }
        await vm.refreshAsync()
    }
}
