import SwiftUI

struct SimMenu: View {
    @EnvironmentObject private var store: Store
    let sim: Sim
    let state: RunState

    var body: some View {
        if sim.isUsable {
            Button("Show in \(SimCtl.windowAppName)", systemImage: "macwindow") { SimCtl.showWindow(sim.id) }
                .disabled(!state.canStop)
            Divider()
            Button("Rename…", systemImage: "pencil") { store.sheet = .simRename(sim) }
            Button("Duplicate…", systemImage: "plus.square.on.square") { store.sheet = .simClone(sim) }
                .disabled(state != .stopped)
            Button("Erase All Content and Settings…", systemImage: "eraser") { store.pending = .eraseSim(sim) }
                .disabled(state != .stopped)
            Divider()
        }
        Button("Show on Disk", systemImage: "folder") { store.reveal(sim) }
            .disabled(sim.folder == nil)
        Button("View Details", systemImage: "info.circle") { store.sheet = .simDetails(sim) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { store.pending = .deleteSim(sim) }
            .disabled(state != .stopped)
    }
}

struct SimDetailsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let sim: Sim

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    row("Name", sim.name)
                    row("UDID", sim.id)
                    row("Status", store.simRunning[sim.id] == nil ? "Shut down" : "Booted")
                    if let problem = sim.problem { row("Problem", problem) }
                }
                Section("System") {
                    row("Runtime", sim.runtime)
                    row("Device type", sim.model)
                }
                Section("Disk") {
                    row("Size on disk", sim.size.map(DiskUsage.format))
                    row("Folder", sim.folder?.path)
                    row("simctl", SimCtl.path)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Show on Disk") { store.reveal(sim) }.disabled(sim.folder == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 440)
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

/// What `simctl` can drive. Home, Lock and Rotate only exist in the simulator's window (Simulator.app, or DeviceHub on Xcode 27).
struct SimControlsCard: View {
    @EnvironmentObject private var store: Store
    let sim: Sim
    @State private var showURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Controls")
                Spacer()
                Text("Home, Lock and Rotate live in \(SimCtl.windowAppName)’s window")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ControlTile("macwindow", "Window") { SimCtl.showWindow(sim.id) }
                ControlTile("link", "Open URL") { showURL.toggle() }
                    .popover(isPresented: $showURL, arrowEdge: .bottom) { OpenURLView(device: SimDevice(udid: sim.id)) }
                ControlTile("camera", "Screenshot") { store.screenshot(sim) }
                    .help("Saved to the Desktop and copied")
                RecordTile(startedAt: store.recordings[sim.id], limit: nil) { store.toggleRecording(sim) }
            }
        }
        .card()
    }
}

struct SimUICard: View {
    let device: SimDevice
    @State private var settings: SimUISettings?
    @State private var app = ""
    @State private var language = ""
    @State private var relaunchStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle("Device UI")
                Spacer()
                if settings != nil {
                    Button("Reset") { reset() }
                        .buttonStyle(.app(.ghost, size: .small))
                        .help("Light appearance, default text size, no increased contrast, real status bar")
                }
            }
            .padding(.bottom, 4)
            if let settings {
                content(settings)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .toggleStyle(AppToggleStyle())
        .card()
        .task(id: device.udid) {
            settings = await device.readUI()
            app = settings?.apps.first?.id ?? ""
        }
    }

    @ViewBuilder
    private func content(_ current: SimUISettings) -> some View {
        SettingRow { Toggle("Dark appearance", isOn: bind(\.dark) { await device.setDark($0) }) }
        SettingRow { Toggle("Increase contrast", isOn: bind(\.increaseContrast) { await device.setIncreaseContrast($0) }) }
        SettingRow { Toggle("Clean status bar (9:41)", isOn: bind(\.cleanStatusBar) { await device.setCleanStatusBar($0) }) }
        SettingRow(last: current.apps.isEmpty) {
            Stepped(
                title: "Text size",
                values: SimDevice.contentSizes.indices.map(Double.init),
                selected: Double(SimDevice.contentSizes.firstIndex { $0.id == current.contentSize } ?? 3),
                label: { SimDevice.contentSizes[Int($0)].label }
            ) { index in
                let size = SimDevice.contentSizes[Int(index)].id
                settings?.contentSize = size
                Task { await device.setContentSize(size) }
            }
        }
        if !current.apps.isEmpty {
            SettingRow(last: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App language")
                    Picker("App", selection: $app) {
                        ForEach(current.apps, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    HStack {
                        Picker("Language", selection: $language) {
                            ForEach(SimDevice.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        Button("Relaunch") { relaunch() }
                            .buttonStyle(.app(.outlined, size: .small))
                            .disabled(app.isEmpty)
                    }
                    Text(relaunchStatus ?? "Relaunches the app in that language, like an Xcode scheme’s App Language.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bind(_ path: WritableKeyPath<SimUISettings, Bool>, apply: @escaping (Bool) async -> Void) -> Binding<Bool> {
        Binding(
            get: { settings![keyPath: path] },
            set: { value in
                settings?[keyPath: path] = value
                Task { await apply(value) }
            }
        )
    }

    private func relaunch() {
        let bundle = app
        let chosen = language
        relaunchStatus = "Relaunching…"
        Task {
            let failure = await device.relaunch(bundle, language: chosen)
            relaunchStatus = failure.map { "Failed: \($0)" } ?? "Relaunched."
        }
    }

    private func reset() {
        settings?.dark = false
        settings?.increaseContrast = false
        settings?.cleanStatusBar = false
        settings?.contentSize = "large"
        Task {
            await device.setDark(false)
            await device.setIncreaseContrast(false)
            await device.setCleanStatusBar(false)
            await device.setContentSize("large")
        }
    }
}

struct OpenURLView: View {
    let device: SimDevice
    @AppStorage("lastOpenedURL") private var url = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open URL").font(.headline)
            HStack {
                TextField("https://… or myapp://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
                Button("Open", action: open).disabled(url.isEmpty)
            }
            Text(failure ?? "A deep link opens in the app that owns its scheme; a web link opens in Safari.")
                .font(.caption)
                .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func open() {
        let target = url.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        failure = nil
        Task { failure = await device.openURL(target) }
    }
}
