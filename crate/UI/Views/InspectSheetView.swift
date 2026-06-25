import SwiftUI
import AppKit

/// Generic sheet that displays raw JSON (or other text) returned from `container inspect …`.
struct InspectSheetView: View {
    let title: String
    let load: () async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var isLoading: Bool = true
    @State private var copyConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title3).bold()
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copyConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copyConfirmation = false
                    }
                } label: {
                    Label(copyConfirmation ? "Copied" : "Copy", systemImage: copyConfirmation ? "checkmark" : "doc.on.doc")
                }
                .disabled(text.isEmpty || isLoading)
                .help("Copy raw inspect output to clipboard")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            text = await load() ?? "(no output)"
            isLoading = false
        }
    }
}
