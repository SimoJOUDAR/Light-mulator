import SwiftUI

enum Library: String, CaseIterable {
    case all, running, connected, android, ios, images, leftovers
}

enum Item: Hashable {
    case avd(String), sim(String), phone(String), iosDevice(String), image(String), leftover(String)
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @SceneStorage("library") private var library = Library.all
    @State private var selection: Item?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(library: $library)
                .navigationSplitViewColumnWidth(min: 236, ideal: 262, max: 320)
        } content: {
            ItemList(library: library, search: search, selection: $selection)
                .navigationSplitViewColumnWidth(min: 344, ideal: 372, max: 480)
        } detail: {
            InspectorView(item: selection)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search devices")
        .navigationTitle("Light-mulator")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.activeCount > 1 {
                    Button("Stop All", systemImage: "stop.circle") { store.stopAll() }
                        .help("Stop every running emulator and simulator")
                }
                Button("Refresh", systemImage: "arrow.clockwise") { store.reload() }
                    .help("Refresh (⌘R)")
                Menu {
                    Button("Open AVD Folder", systemImage: "folder") { store.openAVDFolder() }
                    Button("Open Launch Logs", systemImage: "doc.text") { store.openLogs() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .modifier(StoreOverlays())
        .onChange(of: store.lastPlugged) { _, plugged in
            guard let plugged else { return }
            if library != .all && library != .connected { library = .connected }
            selection = plugged.item
        }
    }

    private var summary: String {
        let devices = store.avds.count + store.sims.count + store.connectedCount
        var parts = ["\(devices) device\(devices == 1 ? "" : "s")"]
        if store.connectedCount > 0 { parts.append("\(store.connectedCount) connected") }
        if store.activeCount > 0 { parts.append("\(store.activeCount) running") }
        if let memory = store.memory {
            parts.append("RAM \(Format.memoryNumber(memory.used)) / \(Format.wholeMemory(memory.total))")
        }
        if let free = store.freeSpace { parts.append("\(Format.diskNumber(free)) GB free") }
        return parts.joined(separator: " · ")
    }
}

/// Alerts, confirmations, sheets and the toast, shared by the whole window.
struct StoreOverlays: ViewModifier {
    @EnvironmentObject private var store: Store

    func body(content: Content) -> some View {
        content
            .alert(
                store.alert?.title ?? "",
                isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } }),
                presenting: store.alert
            ) { _ in
                Button("OK") {}
            } message: { item in
                Text(item.message)
            }
            .sheet(item: $store.sheet) { sheet in
                switch sheet {
                case .details(let avd): DetailsView(avd: avd)
                case .edit(let avd): EditView(avd: avd)
                case .duplicate(let avd): DuplicateView(avd: avd)
                case .simDetails(let sim): SimDetailsView(sim: sim)
                case .simRename(let sim):
                    NameSheet(title: "Rename “\(sim.name)”", initial: sim.name, confirm: "Rename", note: nil) {
                        store.rename(sim, to: $0)
                    }
                case .simClone(let sim):
                    NameSheet(
                        title: "Duplicate “\(sim.name)”",
                        initial: "\(sim.name) Copy",
                        confirm: "Duplicate",
                        note: "Same runtime, same apps and data. The copy is an APFS clone: no extra disk until it diverges."
                    ) { store.clone(sim, as: $0) }
                }
            }
            .background(ConfirmationHost())
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var store: Store
    @Binding var library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Library").padding(.horizontal, 12).padding(.bottom, 6)
                    entry(.all, "All devices", count: store.avds.count + store.sims.count + store.connectedCount) {
                        Image(systemName: "laptopcomputer.and.iphone")
                    }
                    entry(.running, "Running", count: store.activeCount) {
                        StatusDot(color: store.activeCount > 0 ? Theme.good : Theme.undefined)
                    }
                    if store.paths.hasAdb || UsbmuxTracker.isAvailable {
                        entry(.connected, "Connected devices", count: store.connectedCount) {
                            Image(systemName: "cable.connector")
                        }
                    }
                    entry(.android, "Android emulators", count: store.avds.count) {
                        Image(systemName: "smartphone")
                    }
                    if store.hasSimulators {
                        entry(.ios, "iOS simulators", count: store.sims.count) {
                            Image(systemName: "apple.logo")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Maintenance").padding(.horizontal, 12).padding(.bottom, 6)
                    SidebarEntry(
                        title: "System images",
                        selected: library == .images,
                        icon: { Image(systemName: "shippingbox") },
                        trailing: {
                            if store.unusedImages.isEmpty {
                                Text("0").foregroundStyle(Theme.textSecondary)
                            } else {
                                AppTag(label: "\(store.unusedImages.count) unused", variant: .moderate)
                            }
                        }
                    ) { library = .images }
                    SidebarEntry(
                        title: "Leftover files",
                        selected: library == .leftovers,
                        icon: { Image(systemName: "trash") },
                        trailing: {
                            if store.leftovers.isEmpty {
                                AppTag(label: "Clean", variant: .good)
                            } else {
                                AppTag(label: "\(store.leftovers.count)", variant: .moderate)
                            }
                        }
                    ) { library = .leftovers }
                }

                MemoryCard()
                StorageCard()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .background(Theme.surface)
    }

    private func entry(_ value: Library, _ title: String, count: Int, @ViewBuilder icon: () -> some View) -> some View {
        SidebarEntry(
            title: title,
            selected: library == value,
            icon: icon,
            trailing: { Text("\(count)").foregroundStyle(Theme.textSecondary).monospacedDigit() }
        ) { library = value }
    }
}

private struct SidebarEntry<Icon: View, Trailing: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder let icon: Icon
    @ViewBuilder let trailing: Trailing
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.font(.system(size: 14)).frame(width: 18)
                Text(title).fontWeight(selected ? .medium : .regular)
                Spacer(minLength: 4)
                trailing
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                selected ? Theme.card : hovering ? Theme.cardPressed.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.divider : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MemoryCard: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if let memory = store.memory {
            let devices = store.runningDevices
            let deviceTotal = devices.map(\.memory).reduce(0, +)
            let others = memory.used > deviceTotal ? memory.used - deviceTotal : 0
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow("Mac memory")
                    Spacer()
                    pressureTag(memory.pressure)
                }
                BigNumber(
                    value: Format.memoryNumber(memory.used),
                    unit: "GB",
                    caption: "of \(Format.wholeMemory(memory.total)) used"
                )
                StackedBar(
                    segments: devices.enumerated().map { index, device in
                        .init(id: device.id, value: Double(device.memory), color: color(index))
                    } + [.init(id: "other", value: Double(others), color: Theme.otherUse)],
                    total: Double(memory.total)
                )
                .help("Memory used by each running device, by other apps, and free")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        LegendRow(color: color(index), label: device.name, value: Format.memory(device.memory))
                    }
                    LegendRow(color: Theme.otherUse, label: "Other apps", value: Format.memory(others))
                    LegendRow(color: nil, label: "Free", value: Format.memory(memory.available))
                    HStack {
                        Text("Swap in use").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(Format.memory(memory.swapUsed))
                            .foregroundStyle(memory.swapUsed > 2_147_483_648 ? Theme.moderateText : Theme.textSecondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .padding(.top, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.dividerSoft).frame(height: 1) }
                    .help("Memory macOS moved to disk. Above a few GB, everything slows down.")
                }
            }
            .card()
        }
    }

    private func color(_ index: Int) -> Color { Theme.series[index % Theme.series.count] }

    private func pressureTag(_ pressure: MacMemory.Pressure) -> some View {
        switch pressure {
        case .normal: AppTag(label: "Normal", variant: .good)
        case .warning: AppTag(label: "Moderate", variant: .moderate)
        case .critical: AppTag(label: "Critical", variant: .bad)
        }
    }
}

private struct StorageCard: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if let free = store.freeSpace, let total = store.diskTotal {
            let runtimes = store.runtimes.map(\.size).reduce(0, +)
            let parts: [(id: String, label: String, size: Int64, color: Color)] = [
                ("android", "Android emulators", store.androidSize, Theme.series[2]),
                ("ios", "iOS simulators", store.simulatorSize, Theme.series[0]),
                ("runtimes", store.runtimes.count == 1 ? "\(store.runtimes[0].name) runtime" : "iOS runtimes", runtimes, Theme.series[1]),
                ("images", "System images", store.imagesTotalSize, Theme.series[3]),
            ].filter { $0.size > 0 }
            let emulators = parts.map(\.size).reduce(0, +)
            let others = max(0, total - free - emulators)
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Storage")
                BigNumber(value: Format.diskNumber(free), unit: "GB", caption: "free of \(Format.wholeDisk(total))")
                StackedBar(
                    segments: parts.map { .init(id: $0.id, value: Double($0.size), color: $0.color) }
                        + [.init(id: "other", value: Double(others), color: Theme.otherDisk)],
                    total: Double(total)
                )
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parts, id: \.id) { part in
                        LegendRow(color: part.color, label: part.label, value: DiskUsage.format(part.size))
                    }
                    LegendRow(color: Theme.otherDisk, label: "Everything else", value: DiskUsage.format(others))
                }
            }
            .card()
        }
    }
}

// MARK: - List

private enum Row: Identifiable {
    case avd(AVD), sim(Sim), phone(ConnectedDevice), iosDevice(IOSDevice), image(SystemImage), leftover(Leftover)

    var id: Item {
        switch self {
        case .avd(let avd): .avd(avd.id)
        case .sim(let sim): .sim(sim.id)
        case .phone(let phone): .phone(phone.id)
        case .iosDevice(let device): .iosDevice(device.id)
        case .image(let image): .image(image.id)
        case .leftover(let item): .leftover(item.id)
        }
    }
}

private struct ListSection: Identifiable {
    let id: String
    let title: String
    let rows: [Row]
}

private struct ItemList: View {
    @EnvironmentObject private var store: Store
    let library: Library
    let search: String
    @Binding var selection: Item?
    @FocusState private var focused: Bool

    var body: some View {
        let sections = makeSections()
        let ids = sections.flatMap { $0.rows.map(\.id) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    header
                    ForEach(sections) { section in
                        Eyebrow(section.title)
                            .padding(.horizontal, 12)
                            .padding(.top, section.id == sections.first?.id ? 6 : 16)
                            .padding(.bottom, 4)
                        ForEach(section.rows) { row in
                            rowView(row)
                                .id(row.id)
                                .onTapGesture {
                                    selection = row.id
                                    focused = true
                                }
                        }
                    }
                }
                .padding(12)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: ids, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: ids, proxy); return .handled }
        }
        .background(Theme.surface)
        .overlay { if ids.isEmpty { emptyState } }
        .onAppear {
            keepSelection(ids)
            // Otherwise macOS hands first focus to a control in the inspector and scrolls to it.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: ids) { keepSelection(ids) }
        .onChange(of: library) { keepSelection(ids) }
    }

    @ViewBuilder
    private var header: some View {
        switch library {
        case .images where !store.unusedImages.isEmpty:
            Text("No emulator boots from these images. Android Studio’s SDK Manager can download any of them again.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        case .leftovers where !store.leftovers.isEmpty:
            HStack {
                Text("\(DiskUsage.format(store.leftoverSize)) that nothing reads.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Delete All…") { store.pending = .deleteAllLeftovers }
                    .buttonStyle(.app(.outlined, size: .small, destructive: true))
                    .disabled(!store.leftoverBusy.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        default:
            EmptyView()
        }
    }

    private func makeSections() -> [ListSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        func matches(_ fields: [String?]) -> Bool {
            query.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
        switch library {
        case .images:
            let rows = store.unusedImages.filter { matches([$0.title, $0.id]) }.map(Row.image)
            let size = store.reclaimableImageSize
            return rows.isEmpty ? [] : [ListSection(
                id: "images",
                title: "Unused · \(rows.count)\(size > 0 ? " · \(DiskUsage.format(size)) to reclaim" : "")",
                rows: rows
            )]
        case .leftovers:
            let rows = store.leftovers.filter { matches([$0.title, $0.detail]) }.map(Row.leftover)
            return rows.isEmpty ? [] : [ListSection(id: "leftovers", title: "Left behind · \(rows.count)", rows: rows)]
        case .connected:
            let rows = phones(matches)
            return rows.isEmpty ? [] : [ListSection(id: "connected", title: "Connected · \(rows.count)", rows: rows)]
        case .all, .running, .android, .ios:
            let phones = library == .all ? phones(matches) : []
            let avds = library == .ios ? [] : store.avds.filter {
                matches([$0.displayName, $0.id, $0.androidVersion.map { "Android \($0)" }, $0.variant])
            }
            let sims = library == .android ? [] : store.sims.filter { matches([$0.name, $0.runtime, $0.model]) }
            let active = avds.filter { store.state(of: $0).isActive }.map(Row.avd)
                + sims.filter { store.state(of: $0).isActive }.map(Row.sim)
            let ready = library == .running ? [] : avds.filter { !store.state(of: $0).isActive }.map(Row.avd)
                + sims.filter { !store.state(of: $0).isActive }.map(Row.sim)
            return [
                ListSection(id: "connected", title: "Connected · \(phones.count)", rows: phones),
                ListSection(id: "running", title: "Running · \(active.count)", rows: active),
                ListSection(id: "ready", title: "Ready · \(ready.count)", rows: ready),
            ].filter { !$0.rows.isEmpty }
        }
    }

    private func phones(_ matches: ([String?]) -> Bool) -> [Row] {
        let android = store.connected.filter { phone in
            let info = store.phoneInfo[phone.id]
            return matches([store.name(of: phone), phone.serial, info?.manufacturer, info?.androidVersion.map { "Android \($0)" }])
        }
        let apple = store.iosDevices.filter { device in
            let info = store.iosInfo[device.id]
            return matches([store.name(of: device), info?.model, info?.osVersion.map { "iOS \($0)" }, device.udid])
        }
        return android.map(Row.phone) + apple.map(Row.iosDevice)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let selected = selection == row.id
        switch row {
        case .avd(let avd): AVDListRow(avd: avd, selected: selected)
        case .sim(let sim): SimListRow(sim: sim, selected: selected)
        case .phone(let phone): PhoneListRow(phone: phone, selected: selected)
        case .iosDevice(let device): IOSDeviceListRow(device: device, selected: selected)
        case .image(let image):
            ListRow(
                symbol: image.isEmptyFolder ? "folder" : "shippingbox",
                tone: .idle,
                title: image.title,
                subtitle: [image.abi, image.isEmptyFolder ? "nothing inside" : nil].compactMap { $0 }.joined(separator: " · "),
                selected: selected
            ) {
                if store.imageBusy.contains(image.id) {
                    BusyLabel(text: "Deleting…")
                } else {
                    Text(image.isEmptyFolder ? "Empty" : store.imageSizes[image.id].map(DiskUsage.format) ?? "…")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .contextMenu {
                Button("Show in Finder", systemImage: "folder") { store.reveal(image) }
                Button("Delete…", systemImage: "trash", role: .destructive) { store.pending = .deleteImage(image) }
            }
        case .leftover(let item):
            ListRow(symbol: symbol(item.kind), tone: .warning, title: item.title, subtitle: item.detail, selected: selected) {
                if store.leftoverBusy.contains(item.id) {
                    BusyLabel(text: "Deleting…")
                } else {
                    Text(DiskUsage.format(item.size)).foregroundStyle(Theme.textSecondary)
                }
            }
            .contextMenu {
                Button("Show in Finder", systemImage: "folder") { store.reveal(item) }.disabled(item.urls.isEmpty)
                Button("Delete…", systemImage: "trash", role: .destructive) { store.pending = .deleteLeftover(item) }
            }
        }
    }

    private func symbol(_ kind: Leftover.Kind) -> String {
        switch kind {
        case .emulatorLog, .launchLog, .simulatorLogs: "doc.text"
        case .brokenAVD: "smartphone"
        case .unavailableSims: "iphone"
        }
    }

    private var emptyState: some View {
        Group {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                switch library {
                case .running:
                    ContentUnavailableView("Nothing running", systemImage: "moon.zzz", description: Text("Your Mac’s memory is all yours."))
                case .connected:
                    ContentUnavailableView(
                        "No device connected",
                        systemImage: "cable.connector.slash",
                        description: Text("Plug in an iPhone, an iPad, or an Android device with USB debugging on.")
                    )
                case .images:
                    ContentUnavailableView("No unused images", systemImage: "checkmark.seal", description: Text("Every system image backs an emulator."))
                case .leftovers:
                    ContentUnavailableView("Nothing left behind", systemImage: "checkmark.seal", description: Text("Deleted devices left no files."))
                default:
                    ContentUnavailableView("No devices", systemImage: "iphone.slash", description: Text("Nothing in \(store.paths.avdHome.path)"))
                }
            }
        }
    }

    private func keepSelection(_ ids: [Item]) {
        if selection == nil || !ids.contains(selection!) { selection = ids.first }
    }

    private func move(_ step: Int, in ids: [Item], _ proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let next = ids[min(max(index + step, 0), ids.count - 1)]
        selection = next
        proxy.scrollTo(next)
    }
}

private struct AVDListRow: View {
    @EnvironmentObject private var store: Store
    let avd: AVD
    let selected: Bool

    var body: some View {
        let state = store.state(of: avd)
        let need = store.ramNeed(avd.id)
        let tight = state == .stopped && store.memoryWarning(need: need) != nil
        ListRow(
            symbol: avd.symbol == "iphone" ? "smartphone" : avd.symbol,
            tone: avd.problem != nil ? .warning : state.isActive ? .active : .idle,
            title: avd.displayName,
            subtitle: subtitle(state, need: need),
            subtitleColor: avd.problem != nil ? Theme.moderateText : tight ? Theme.moderateText : Theme.textSecondary,
            selected: selected
        ) {
            DeviceTrailing(state: state, memory: store.running[avd.id]?.memory, size: store.sizes[avd.id])
        }
        .contextMenu { RowMenu(avd: avd, state: state) }
    }

    private func subtitle(_ state: RunState, need: UInt64?) -> String {
        if let problem = avd.problem { return problem }
        let version = avd.androidVersion.map { "Android \($0)" } ?? avd.apiLevel.map { "API \($0)" } ?? "Android"
        if state == .stopped, let need { return "\(version) · needs ≈ \(Format.memory(need)) RAM" }
        return [version, avd.variant].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct SimListRow: View {
    @EnvironmentObject private var store: Store
    let sim: Sim
    let selected: Bool

    var body: some View {
        let state = store.state(of: sim)
        let need = store.ramNeed(sim.id)
        let tight = state == .stopped && store.memoryWarning(need: need) != nil
        ListRow(
            symbol: sim.symbol,
            tone: sim.problem != nil ? .warning : state.isActive ? .active : .idle,
            title: sim.name,
            subtitle: sim.problem ?? (state == .stopped && need != nil
                ? "\(sim.runtime) · needs ≈ \(Format.memory(need!)) RAM" : sim.runtime),
            subtitleColor: sim.problem != nil || tight ? Theme.moderateText : Theme.textSecondary,
            selected: selected
        ) {
            DeviceTrailing(state: state, memory: store.simRunning[sim.id]?.memory, size: sim.size)
        }
        .contextMenu { SimMenu(sim: sim, state: state) }
    }
}

private struct PhoneListRow: View {
    @EnvironmentObject private var store: Store
    let phone: ConnectedDevice
    let selected: Bool

    var body: some View {
        let info = store.phoneInfo[phone.id]
        ListRow(
            symbol: info?.isTablet == true ? "ipad.landscape" : "smartphone",
            tone: phone.isReady ? .active : .warning,
            title: store.name(of: phone),
            subtitle: phone.isReady
                ? [info?.androidVersion.map { "Android \($0)" }, phone.usb ? "USB" : "Wi-Fi"].compactMap { $0 }.joined(separator: " · ")
                : phone.state == "unauthorized" ? "Allow USB debugging on the device" : phone.state.capitalized,
            subtitleColor: phone.isReady ? Theme.textSecondary : Theme.moderateText,
            selected: selected
        ) {
            if let battery = info?.battery {
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol(battery))
                    Text("\(battery.level) %").monospacedDigit()
                }
                .foregroundStyle(battery.level <= 15 && !battery.charging ? Theme.moderateText : Theme.textSecondary)
                .help(battery.charging ? "Battery, charging" : "Battery")
            } else if phone.isReady {
                Text(phone.usb ? "USB" : "Wi-Fi").foregroundStyle(Theme.placeholder)
            }
        }
        .contextMenu { PhoneMenu(phone: phone) }
    }

    private static func symbol(_ battery: PhoneInfo.Battery) -> String {
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct IOSDeviceListRow: View {
    @EnvironmentObject private var store: Store
    let device: IOSDevice
    let selected: Bool

    var body: some View {
        let info = store.iosInfo[device.id]
        ListRow(
            symbol: info?.isPad == true ? "ipad.landscape" : "iphone",
            tone: info?.isControllable == true ? .active : .warning,
            title: store.name(of: device),
            subtitle: subtitle(info),
            subtitleColor: info?.isControllable == true ? Theme.textSecondary : Theme.moderateText,
            selected: selected
        ) {
            Text("USB").foregroundStyle(Theme.placeholder)
        }
        .contextMenu { IOSDeviceMenu(device: device) }
    }

    private func subtitle(_ info: IOSDeviceInfo?) -> String {
        guard let info else { return "Connecting…" }
        if !info.paired { return "Tap Trust on the device" }
        if info.developerMode == false { return "Developer Mode is off" }
        if info.preparing { return "Preparing for development…" }
        return [info.model, info.osVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct DeviceTrailing: View {
    let state: RunState
    let memory: UInt64?
    let size: Int64?

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 6) {
                StatusDot(color: Theme.good)
                Text(memory.map(Format.memory) ?? "Running").foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            .help("Memory used now, as in Activity Monitor")
        case .starting: BusyLabel(text: "Starting…")
        case .booting: BusyLabel(text: memory.map { "Booting · \(Format.memory($0))" } ?? "Booting…")
        case .working(let label): BusyLabel(text: label)
        case .stopped:
            Text(size.map(DiskUsage.format) ?? "").foregroundStyle(Theme.placeholder).monospacedDigit()
        }
    }
}

struct BusyLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ListRow<Trailing: View>: View {
    enum Tone { case idle, active, warning }

    let symbol: String
    let tone: Tone
    let title: String
    let subtitle: String
    var subtitleColor = Theme.textSecondary
    let selected: Bool
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .foregroundStyle(iconColors.fg)
                .background(iconColors.bg, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(subtitleColor).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            trailing.font(.system(size: 12)).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            selected ? Theme.card : hovering ? Theme.cardPressed.opacity(0.6) : .clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.divider : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var iconColors: (bg: Color, fg: Color) {
        switch tone {
        case .idle: (Theme.neutralTag, Theme.textSecondary)
        case .active: (Theme.goodBackground, Theme.goodText)
        case .warning: (Theme.moderateBackground, Theme.moderateText)
        }
    }
}
