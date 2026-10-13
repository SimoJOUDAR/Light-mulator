import SwiftUI

/// Toast: ink capsule, white text.
struct ToastView: View {
    @EnvironmentObject private var store: Store
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message).font(.system(size: 13))
            if let file = toast.file {
                Button("Open") { NSWorkspace.shared.open(file) }.buttonStyle(.plain).fontWeight(.semibold)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
            }
            Button { store.dismissToast() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .opacity(0.7)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(light: 0x0F0F0F, dark: 0x2D2B28), in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

/// Lives on its own view: two `.alert`s on the same view would shadow each other.
struct ConfirmationHost: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Color.clear.alert(
            title,
            isPresented: Binding(get: { store.pending != nil }, set: { if !$0 { store.pending = nil } }),
            presenting: store.pending
        ) { action in
            Button(confirmLabel(action), role: .destructive) { store.confirm(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(message(action))
        }
    }

    private var title: String {
        switch store.pending {
        case .delete(let avd): "Delete “\(avd.displayName)”?"
        case .wipe(let avd): "Wipe data of “\(avd.displayName)”?"
        case .forceKill(let avd): "Force kill “\(avd.displayName)”?"
        case .deleteSim(let sim): "Delete “\(sim.name)”?"
        case .eraseSim(let sim): "Erase “\(sim.name)”?"
        case .deleteImage(let image):
            image.isEmptyFolder ? "Remove the empty folder \(image.id)?" : "Delete the \(image.title) system image?"
        case .deleteLeftover(let item): "Delete \(item.title)?"
        case .deleteAllLeftovers: "Delete all leftover files?"
        case nil: ""
        }
    }

    private func confirmLabel(_ action: PendingAction) -> String {
        switch action {
        case .delete, .deleteSim, .deleteImage, .deleteLeftover: "Delete"
        case .deleteAllLeftovers: "Delete All"
        case .wipe: "Wipe Data"
        case .forceKill: "Force Kill"
        case .eraseSim: "Erase"
        }
    }

    private func message(_ action: PendingAction) -> String {
        switch action {
        case .delete(let avd):
            let size = store.sizes[avd.id].map { " and frees \(DiskUsage.format($0))" } ?? ""
            return "This permanently removes the emulator\(size). It can’t be undone."
        case .wipe:
            return "Apps, accounts, settings and snapshots are erased. The next boot starts like a new device."
        case .forceKill:
            return "The emulator is stopped immediately. Unsaved state and the quick-boot snapshot are lost."
        case .deleteSim(let sim):
            let size = sim.size.map { " and frees \(DiskUsage.format($0))" } ?? ""
            return "This permanently removes the simulator, its apps and data\(size). It can’t be undone."
        case .eraseSim:
            return "All content and settings are erased: apps, data, keychain. The next boot starts like a new device."
        case .deleteImage(let image):
            if image.isEmptyFolder { return "It holds no image: nothing is lost." }
            let size = store.imageSizes[image.id].map { "Frees \(DiskUsage.format($0)). " } ?? ""
            return "No emulator uses it. \(size)Android Studio’s SDK Manager can download it again."
        case .deleteLeftover(let item):
            return "\(item.explanation) Frees \(DiskUsage.format(item.size))."
        case .deleteAllLeftovers:
            let names = store.leftovers.map(\.title).joined(separator: ", ")
            return "\(names). Nothing reads them. Frees \(DiskUsage.format(store.leftoverSize))."
        }
    }
}

struct RowMenu: View {
    @EnvironmentObject private var store: Store
    let avd: AVD
    let state: RunState

    var body: some View {
        if avd.isUsable {
            Button("Cold Boot", systemImage: "snowflake") { store.launch(avd, coldBoot: true) }
                .disabled(!state.canLaunch)
            Divider()
            Button("Edit…", systemImage: "pencil") { store.sheet = .edit(avd) }
                .disabled(state != .stopped)
            Button("Duplicate…", systemImage: "plus.square.on.square") { store.sheet = .duplicate(avd) }
                .disabled(state != .stopped)
            Button("Wipe Data…", systemImage: "eraser") { store.pending = .wipe(avd) }
                .disabled(state != .stopped)
            Divider()
        }
        Button("Show on Disk", systemImage: "folder") { store.reveal(avd) }
        Button("View Details", systemImage: "info.circle") { store.sheet = .details(avd) }
        Divider()
        Button("Force Kill", systemImage: "bolt.slash") { store.pending = .forceKill(avd) }
            .disabled(!state.isAlive)
        Button("Delete…", systemImage: "trash", role: .destructive) { store.pending = .delete(avd) }
            .disabled(state != .stopped)
    }
}

// MARK: - Sheets

struct DetailsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let avd: AVD

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    row("Name", avd.displayName)
                    row("ID", avd.id)
                    row("Status", status)
                    if let problem = avd.problem { row("Problem", problem) }
                }
                Section("System") {
                    row("API level", avd.apiLevel.map { api in avd.androidVersion.map { "\(api) (Android \($0))" } ?? "\(api)" })
                    row("Image", avd.config["image.sysdir.1"])
                    row("Variant", avd.variant)
                    row("ABI", avd.config["abi.type"])
                }
                Section("Hardware") {
                    row("Device", avd.config["hw.device.name"])
                    row("Screen", avd.screen.map { s in avd.config["hw.lcd.density"].map { "\(s) · \($0) dpi" } ?? s })
                    row("RAM", avd.config["hw.ramSize"].map { "\($0) MB" })
                    row("VM heap", avd.config["vm.heapSize"].map { "\($0) MB" })
                    row("CPU cores", avd.config["hw.cpu.ncore"])
                    row("Internal storage", avd.config["disk.dataPartition.size"])
                    row("SD card", avd.config["sdcard.size"])
                    row("GPU", avd.config["hw.gpu.mode"])
                    row("Boot", avd.config["fastboot.forceColdBoot"] == "yes" ? "Cold boot" : "Quick boot")
                }
                Section("Disk") {
                    row("Size on disk", store.sizes[avd.id].map(DiskUsage.format))
                    row("Folder", avd.dir.path)
                    row("SDK", store.paths.sdk.path)
                }
                if !avd.config.isEmpty {
                    Section("config.ini") {
                        Text(avd.config.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Show on Disk") { store.reveal(avd) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 600)
    }

    private var status: String {
        guard let info = store.running[avd.id] else { return "Stopped" }
        var text = "Running · PID \(info.pid)"
        if let port = info.consolePort { text += " · emulator-\(port)" }
        return text
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }
}

struct EditView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let avd: AVD

    @State private var name = ""
    @State private var ram = ""
    @State private var heap = ""
    @State private var cores = 2
    @State private var storage = ""
    @State private var coldBoot = false
    @State private var keyboard = true
    @State private var frame = true
    @State private var gpu = "auto"

    private let maxCores = ProcessInfo.processInfo.activeProcessorCount

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    LabeledContent("ID", value: avd.id)
                }
                Section("Performance") {
                    TextField("RAM (MB)", text: $ram)
                    TextField("VM heap (MB)", text: $heap)
                    Picker("CPU cores", selection: $cores) {
                        ForEach(1...max(maxCores, cores), id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Graphics", selection: $gpu) {
                        Text("Automatic").tag("auto")
                        Text("Hardware").tag("host")
                        Text("Software").tag("swiftshader_indirect")
                        if !["auto", "host", "swiftshader_indirect"].contains(gpu) { Text(gpu).tag(gpu) }
                    }
                    Picker("Boot", selection: $coldBoot) {
                        Text("Quick boot").tag(false)
                        Text("Cold boot").tag(true)
                    }
                }
                Section {
                    TextField("Internal storage", text: $storage, prompt: Text("e.g. 6G"))
                } footer: {
                    Text("Growing the storage applies on the next boot; shrinking it needs a Wipe Data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Hardware keyboard", isOn: $keyboard)
                    Toggle("Show device frame", isOn: $frame)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Open config.ini") { store.openConfig(avd) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: load)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && AVD.megabytes(ram) != nil
            && (heap.isEmpty || AVD.megabytes(heap) != nil)
            && (storage.isEmpty || AVD.megabytes(storage) != nil)
    }

    private func load() {
        let config = avd.config
        name = avd.displayName
        ram = config["hw.ramSize"] ?? "2048"
        heap = config["vm.heapSize"] ?? ""
        cores = Int(config["hw.cpu.ncore"] ?? "") ?? 2
        storage = config["disk.dataPartition.size"] ?? ""
        coldBoot = config["fastboot.forceColdBoot"] == "yes"
        keyboard = config["hw.keyboard"] != "no"
        frame = config["showDeviceFrame"] != "no"
        gpu = config["hw.gpu.mode"] ?? "auto"
    }

    private func save() {
        var updates: [String: String] = [
            "avd.ini.displayname": name.trimmingCharacters(in: .whitespaces),
            "hw.ramSize": ram.trimmingCharacters(in: .whitespaces),
            "hw.cpu.ncore": "\(cores)",
            "hw.gpu.mode": gpu,
            "fastboot.forceColdBoot": coldBoot ? "yes" : "no",
            "fastboot.forceFastBoot": coldBoot ? "no" : "yes",
            "hw.keyboard": keyboard ? "yes" : "no",
            "showDeviceFrame": frame ? "yes" : "no",
        ]
        if !heap.isEmpty { updates["vm.heapSize"] = heap.trimmingCharacters(in: .whitespaces) }
        if !storage.isEmpty { updates["disk.dataPartition.size"] = storage.trimmingCharacters(in: .whitespaces) }
        store.saveEdits(avd, updates)
        dismiss()
    }
}

struct DuplicateView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let avd: AVD
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Duplicate “\(avd.displayName)”").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            Text("ID: \(newID.isEmpty ? "—" : newID)\(exists ? " (already taken)" : "")")
                .font(.caption)
                .foregroundStyle(exists ? Color.red : .secondary)
            Text("The copy is an APFS clone: it takes no extra disk until it diverges. Snapshots aren’t copied, so its first boot is a cold boot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Duplicate", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newID.isEmpty || exists)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = "\(avd.displayName) Copy" }
    }

    private var newID: String { AVDRepository.sanitizedID(name) }
    private var exists: Bool { store.avds.contains { $0.id == newID } }

    private func confirm() {
        guard !newID.isEmpty, !exists else { return }
        store.duplicate(avd, as: name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    let confirm: String
    let note: String?
    let action: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = initial }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        action(trimmed)
        dismiss()
    }
}
