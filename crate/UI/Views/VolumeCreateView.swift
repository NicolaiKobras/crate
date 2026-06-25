import SwiftUI

struct VolumeCreateView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful create with the new volume name.
    var onCreated: ((String) -> Void)? = nil

    @State private var name: String = ""
    @State private var sizeValue: String = ""
    @State private var sizeUnit: SizeUnit = .none
    @State private var labels: [KeyValueEntry] = []
    @State private var options: [KeyValueEntry] = []
    @State private var validationError: String?
    @State private var isCreating: Bool = false

    enum SizeUnit: String, CaseIterable, Identifiable {
        case none = "—"
        case K, M, G, T, P
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "—"
            case .K: return "KiB"
            case .M: return "MiB"
            case .G: return "GiB"
            case .T: return "TiB"
            case .P: return "PiB"
            }
        }
        var suffix: String { self == .none ? "" : rawValue }
    }

    struct KeyValueEntry: Identifiable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create Volume").font(.title2).bold()
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Name") {
                    TextField("Required", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Text("Letters, digits, dashes and underscores work best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Size") {
                    HStack(spacing: 8) {
                        TextField("e.g. 512", text: $sizeValue)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                        Picker("", selection: $sizeUnit) {
                            ForEach(SizeUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Spacer()
                    }
                    Text("Leave empty for an unbounded volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    keyValueEditor(
                        title: "Labels",
                        entries: $labels,
                        keyPlaceholder: "key",
                        valuePlaceholder: "value",
                        addTooltip: "Add a metadata label",
                        emptyHint: "Optional metadata applied to the volume."
                    )
                }

                Section {
                    keyValueEditor(
                        title: "Driver options (--opt)",
                        entries: $options,
                        keyPlaceholder: "key",
                        valuePlaceholder: "value",
                        addTooltip: "Add a driver-specific option",
                        emptyHint: "Optional driver-specific options (e.g. format=ext4)."
                    )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid() || isCreating)
                    .help("Create the volume")
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: - Editor

    @ViewBuilder
    private func keyValueEditor(title: String,
                                entries: Binding<[KeyValueEntry]>,
                                keyPlaceholder: String,
                                valuePlaceholder: String,
                                addTooltip: String,
                                emptyHint: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button {
                entries.wrappedValue.append(KeyValueEntry())
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help(addTooltip)
        }

        if entries.wrappedValue.isEmpty {
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { $entry in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $entry.key)
                        .textFieldStyle(.roundedBorder)
                    Text("=").foregroundStyle(.secondary)
                    TextField(valuePlaceholder, text: $entry.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        entries.wrappedValue.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
        }
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSizeValue: String {
        sizeValue.trimmingCharacters(in: .whitespaces)
    }

    private func isValid() -> Bool {
        guard !trimmedName.isEmpty else { return false }
        if !trimmedSizeValue.isEmpty {
            guard Double(trimmedSizeValue) != nil else { return false }
        }
        return true
    }

    private func validate() -> String? {
        guard !trimmedName.isEmpty else { return "Name is required." }
        if trimmedName.contains(where: { $0.isWhitespace }) {
            return "Name cannot contain spaces."
        }
        if !trimmedSizeValue.isEmpty, Double(trimmedSizeValue) == nil {
            return "Size must be a number."
        }
        for entry in labels {
            let k = entry.key.trimmingCharacters(in: .whitespaces)
            let v = entry.value.trimmingCharacters(in: .whitespaces)
            if k.isEmpty && !v.isEmpty {
                return "Label has a value but no key."
            }
        }
        for entry in options {
            let k = entry.key.trimmingCharacters(in: .whitespaces)
            let v = entry.value.trimmingCharacters(in: .whitespaces)
            if k.isEmpty && !v.isEmpty {
                return "Driver option has a value but no key."
            }
        }
        return nil
    }

    // MARK: - Build args & submit

    private func buildSize() -> String? {
        guard !trimmedSizeValue.isEmpty else { return nil }
        return trimmedSizeValue + sizeUnit.suffix
    }

    private func buildPairs(_ entries: [KeyValueEntry]) -> [String] {
        entries.compactMap { entry in
            let k = entry.key.trimmingCharacters(in: .whitespaces)
            let v = entry.value.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return nil }
            return "\(k)=\(v)"
        }
    }

    @MainActor
    private func create() async {
        if let err = validate() {
            validationError = err
            return
        }
        validationError = nil
        isCreating = true
        let createdName = trimmedName
        await vm.createVolume(
            name: createdName,
            size: buildSize(),
            options: buildPairs(options),
            labels: buildPairs(labels)
        )
        isCreating = false
        onCreated?(createdName)
        dismiss()
    }
}
