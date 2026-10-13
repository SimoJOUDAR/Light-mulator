import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var store: Store
    let item: Item?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .avd(let id):
            if let avd = store.avds.first(where: { $0.id == id }) { AVDInspector(avd: avd).id(id) } else { placeholder }
        case .sim(let id):
            if let sim = store.sims.first(where: { $0.id == id }) { SimInspector(sim: sim).id(id) } else { placeholder }
        case .image(let id):
            if let image = store.unusedImages.first(where: { $0.id == id }) { ImageInspector(image: image) } else { placeholder }
        case .leftover(let id):
            if let item = store.leftovers.first(where: { $0.id == id }) { LeftoverInspector(item: item) } else { placeholder }
        case .phone(let id):
            if let phone = store.connected.first(where: { $0.id == id }) { PhoneInspector(phone: phone).id(id) } else { placeholder }
        case .iosDevice(let id):
            if let device = store.iosDevices.first(where: { $0.id == id }) { IOSDeviceInspector(device: device).id(id) } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Nothing selected", systemImage: "sidebar.right", description: Text("Pick a device to see its controls."))
    }
}

/// The scrolling column every inspector uses.
private struct InspectorPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(24)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private let cardColumns = [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]

// MARK: - Android

private struct AVDInspector: View {
    @EnvironmentObject private var store: Store
    let avd: AVD

    var body: some View {
        let state = store.state(of: avd)
        let info = store.running[avd.id]
        let device = state == .running ? store.device(for: avd) : nil
        InspectorPage {
            InspectorHeader(
                preview: DevicePreview(id: avd.id, live: device != nil, tablet: avd.symbol == "ipad.landscape") {
                    if let device { store.refreshPreview(avd.id, device) }
                },
                kicker: "Android emulator",
                title: avd.displayName,
                subtitle: subtitle,
                status: { StatusLine(state: state, started: info?.started, memory: info?.memory, need: store.ramNeed(avd.id)) }
            ) {
                actions(state)
            }

            if let device {
                AndroidControlsCard(id: avd.id, name: avd.displayName, device: device)
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    AndroidUICard(device: device, apiLevel: avd.apiLevel)
                    AVDDetailsCard(avd: avd, state: state)
                }
            } else {
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    if state == .stopped && avd.isUsable { LaunchMemoryCard(id: avd.id) }
                    AVDDetailsCard(avd: avd, state: state)
                }
            }

            dangerBar(state)
        }
        .task(id: device?.serial) {
            if let device { store.refreshPreview(avd.id, device) }
        }
    }

    private var subtitle: String {
        if let problem = avd.problem { return problem }
        var parts: [String] = []
        if let version = avd.androidVersion { parts.append("Android \(version)") }
        if let api = avd.apiLevel { parts.append("API \(api)") }
        if let variant = avd.variant { parts.append(variant) }
        if let abi = avd.abi { parts.append(abi) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            Button("Launch") { store.launch(avd) }
                .buttonStyle(.app(.primary))
                .disabled(!avd.isUsable)
            if avd.isUsable {
                Button("Cold boot") { store.launch(avd, coldBoot: true) }
                    .buttonStyle(.app(.outlined))
                    .help("Boot from scratch, ignoring the quick-boot snapshot")
            }
        case .starting:
            Button("Launching…") {}.buttonStyle(.app(.primary)).disabled(true)
        case .booting, .running:
            Button("Stop") { store.stop(avd) }
                .buttonStyle(.app(.primary))
                .help("Graceful stop: saves the quick-boot state")
            Button("Show window") { store.showWindow(avd) }
                .buttonStyle(.app(.outlined))
        case .working(let label):
            Button(label) {}.buttonStyle(.app(.primary)).disabled(true)
        }
        MoreMenu { RowMenu(avd: avd, state: state) }
    }

    private func dangerBar(_ state: RunState) -> some View {
        let stopped = state == .stopped
        let size = store.sizes[avd.id].map { "deleting frees \(DiskUsage.format($0))" } ?? "deleting can’t be undone"
        let message = !stopped
            ? "Stop the emulator to duplicate, wipe or delete it."
            : avd.isUsable ? "Wiping erases apps and data; \(size)." : "A broken emulator can only be deleted; \(size)."
        return DangerBar(message: message) {
            if avd.isUsable {
                Button("Duplicate…") { store.sheet = .duplicate(avd) }
                    .buttonStyle(.app(.ghost, size: .small))
                    .disabled(!stopped)
                Button("Wipe data…") { store.pending = .wipe(avd) }
                    .buttonStyle(.app(.outlined, size: .small, destructive: true))
                    .disabled(!stopped)
            }
            Button("Delete…") { store.pending = .delete(avd) }
                .buttonStyle(.app(.ghost, size: .small, destructive: true))
                .disabled(!stopped)
        }
    }
}

private struct AVDDetailsCard: View {
    @EnvironmentObject private var store: Store
    let avd: AVD
    let state: RunState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Details").padding(.bottom, 4)
            DetailRow(label: "System image", value: [avd.variant, avd.abi].compactMap { $0 }.joined(separator: " · "))
            DetailRow(label: "RAM · CPU", value: [ram, avd.config["hw.cpu.ncore"].map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · "))
            DetailRow(label: "Screen", value: screen)
            DetailRow(label: "Density", value: avd.config["hw.lcd.density"].map { "\($0) dpi" })
            DetailRow(label: "Boot", value: avd.config["fastboot.forceColdBoot"] == "yes" ? "Cold boot" : "Quick boot")
            DetailRow(label: "On disk", value: store.sizes[avd.id].map(DiskUsage.format) ?? "…", last: true)
            HStack(spacing: 4) {
                Button("Show in Finder") { store.reveal(avd) }.buttonStyle(.app(.ghost, size: .small))
                Spacer(minLength: 0)
                if avd.isUsable {
                    Button("Edit…") { store.sheet = .edit(avd) }
                        .buttonStyle(.app(.ghost, size: .small))
                        .disabled(state != .stopped)
                        .help(state == .stopped ? "RAM, cores, storage, boot" : "Stop the emulator to edit it")
                }
                Button("All details…") { store.sheet = .details(avd) }.buttonStyle(.app(.ghost, size: .small))
            }
            .padding(.top, 8)
        }
        .card()
    }

    private var ram: String? {
        guard let mb = avd.ramMB else { return nil }
        return mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(Format.decimal(Double(mb) / 1024)) GB"
    }

    private var screen: String? {
        guard let width = avd.config["hw.lcd.width"], let height = avd.config["hw.lcd.height"] else { return nil }
        return "\(width) × \(height)"
    }
}

// MARK: - iOS

private struct SimInspector: View {
    @EnvironmentObject private var store: Store
    let sim: Sim

    var body: some View {
        let state = store.state(of: sim)
        let info = store.simRunning[sim.id]
        let live = state == .running
        InspectorPage {
            InspectorHeader(
                preview: DevicePreview(id: sim.id, live: live, tablet: sim.symbol == "ipad.landscape") { store.refreshPreview(sim) },
                kicker: "iOS simulator",
                title: sim.name,
                subtitle: sim.problem ?? [sim.runtime, sim.model == sim.name ? nil : sim.model].compactMap { $0 }.joined(separator: " · "),
                status: { StatusLine(state: state, started: info?.started, memory: info?.memory, need: store.ramNeed(sim.id)) }
            ) {
                actions(state)
            }

            if live {
                SimControlsCard(sim: sim)
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    SimUICard(device: SimDevice(udid: sim.id))
                    SimDetailsCard(sim: sim)
                }
            } else {
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    if state == .stopped && sim.isUsable { LaunchMemoryCard(id: sim.id) }
                    SimDetailsCard(sim: sim)
                }
            }

            dangerBar(state)
        }
        .task(id: live) {
            if live { store.refreshPreview(sim) }
        }
    }

    @ViewBuilder
    private func actions(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            Button("Launch") { store.launch(sim) }.buttonStyle(.app(.primary)).disabled(!sim.isUsable)
        case .starting:
            Button("Launching…") {}.buttonStyle(.app(.primary)).disabled(true)
        case .booting, .running:
            Button("Shut down") { store.stop(sim) }.buttonStyle(.app(.primary))
            Button("Show in \(SimCtl.windowAppName)") { SimCtl.showWindow(sim.id) }.buttonStyle(.app(.outlined))
        case .working(let label):
            Button(label) {}.buttonStyle(.app(.primary)).disabled(true)
        }
        MoreMenu { SimMenu(sim: sim, state: state) }
    }

    private func dangerBar(_ state: RunState) -> some View {
        let stopped = state == .stopped
        let size = sim.size.map { "deleting frees \(DiskUsage.format($0))" } ?? "deleting can’t be undone"
        return DangerBar(message: stopped
            ? "Erasing resets content and settings; \(size)."
            : "Shut the simulator down to duplicate, erase or delete it.") {
            if sim.isUsable {
                Button("Rename…") { store.sheet = .simRename(sim) }.buttonStyle(.app(.ghost, size: .small))
                Button("Duplicate…") { store.sheet = .simClone(sim) }
                    .buttonStyle(.app(.ghost, size: .small))
                    .disabled(!stopped)
                Button("Erase…") { store.pending = .eraseSim(sim) }
                    .buttonStyle(.app(.outlined, size: .small, destructive: true))
                    .disabled(!stopped)
            }
            Button("Delete…") { store.pending = .deleteSim(sim) }
                .buttonStyle(.app(.ghost, size: .small, destructive: true))
                .disabled(!stopped)
        }
    }
}

private struct SimDetailsCard: View {
    @EnvironmentObject private var store: Store
    let sim: Sim

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Details").padding(.bottom, 4)
            DetailRow(label: "Runtime", value: sim.runtime)
            DetailRow(label: "Device type", value: sim.model)
            DetailRow(label: "On disk", value: sim.size.map(DiskUsage.format))
            DetailRow(label: "UDID", value: sim.id, last: true, identifier: true)
            HStack(spacing: 4) {
                Button("Show in Finder") { store.reveal(sim) }
                    .buttonStyle(.app(.ghost, size: .small))
                    .disabled(sim.folder == nil)
                Spacer(minLength: 0)
                Button("All details…") { store.sheet = .simDetails(sim) }.buttonStyle(.app(.ghost, size: .small))
            }
            .padding(.top, 8)
        }
        .card()
    }
}

// MARK: - Connected devices

private struct PhoneInspector: View {
    @EnvironmentObject private var store: Store
    let phone: ConnectedDevice

    var body: some View {
        let info = store.phoneInfo[phone.id]
        let device = store.device(for: phone)
        let name = store.name(of: phone)
        InspectorPage {
            InspectorHeader(
                preview: DevicePreview(id: phone.id, live: device != nil, tablet: info?.isTablet == true, idleText: "Not ready") {
                    if let device { store.refreshPreview(phone.id, device) }
                },
                kicker: "Connected device",
                title: name,
                subtitle: subtitle(info),
                status: { PhoneStatus(phone: phone, battery: info?.battery) }
            ) {
                if device != nil { actions(name) }
            }

            if let device {
                AndroidControlsCard(id: phone.id, name: name, device: device)
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    AndroidUICard(device: device, apiLevel: info?.apiLevel, physical: true)
                    PhoneDetailsCard(phone: phone, info: info)
                }
            } else {
                WarningNote(text: PhoneStatus.advice(phone.state))
            }
        }
        .task(id: device?.serial) {
            guard let device else { return }
            store.refreshPreview(phone.id, device)
            // The battery is the only thing that moves while it sits on the desk.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                store.refreshBattery(phone)
            }
        }
    }

    private func subtitle(_ info: PhoneInfo?) -> String {
        [
            info?.manufacturer,
            info?.androidVersion.map { "Android \($0)" },
            info?.apiLevel.map { "API \($0)" },
            phone.usb ? "USB" : "Wi-Fi",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ name: String) -> some View {
        if Mirror.path != nil {
            let mirroring = store.mirroring.contains(phone.id)
            Button(mirroring ? "Show mirror" : "Mirror screen") { store.mirror(phone) }
                .buttonStyle(.app(.primary))
                .help("A live window of the screen (scrcpy): click and type in it")
        }
        Button("Open shell") { store.openShell(phone) }
            .buttonStyle(.app(Mirror.path == nil ? .primary : .outlined))
            .help("adb shell on \(name), in Terminal")
        MoreMenu { PhoneMenu(phone: phone) }
    }
}

struct PhoneMenu: View {
    @EnvironmentObject private var store: Store
    let phone: ConnectedDevice

    var body: some View {
        if let device = store.device(for: phone) {
            if Mirror.path != nil {
                Button("Mirror Screen", systemImage: "rectangle.on.rectangle") { store.mirror(phone) }
                if store.mirroring.contains(phone.id) {
                    Button("Stop Mirroring", systemImage: "rectangle.slash") { store.stopMirroring(phone) }
                }
            }
            Button("Screenshot", systemImage: "camera") { store.screenshot(device, name: store.name(of: phone)) }
            Button("Open Shell in Terminal", systemImage: "terminal") { store.openShell(phone) }
            Divider()
        }
        Button("Copy Serial Number", systemImage: "doc.on.doc") { store.copySerial(phone) }
        if !phone.usb {
            Button("Disconnect", systemImage: "wifi.slash") { store.disconnect(phone) }
        }
    }
}

private struct PhoneStatus: View {
    let phone: ConnectedDevice
    let battery: PhoneInfo.Battery?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: phone.isReady ? Theme.good : Theme.moderateText)
            Text(phone.isReady ? "Connected over \(phone.usb ? "USB" : "Wi-Fi")" : Self.label(phone.state))
            if phone.isReady, let battery {
                Text("· \(battery.level) % battery\(battery.charging ? ", charging" : "")").foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    static func label(_ state: String) -> String {
        switch state {
        case "unauthorized": "Waiting for USB debugging approval"
        case "authorizing": "Authorizing…"
        case "offline": "Offline"
        case "no permissions": "No permission to use it"
        default: state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    static func advice(_ state: String) -> String {
        switch state {
        case "unauthorized", "authorizing":
            "Unlock the device and tap Allow on “Allow USB debugging?”. No prompt? Unplug it and plug it back in."
        case "offline":
            "adb lost the device. Unplug it and plug it back in, or turn USB debugging off and on in Developer options."
        case "recovery", "sideload", "bootloader", "rescue":
            "The device is in \(state) mode: controls come back once Android has started."
        default:
            "adb can’t use this device (\(state))."
        }
    }
}

private struct PhoneDetailsCard: View {
    @EnvironmentObject private var store: Store
    let phone: ConnectedDevice
    let info: PhoneInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Details").padding(.bottom, 4)
            if let info {
                DetailRow(label: "Model", value: [info.manufacturer, info.model].compactMap { $0 }.joined(separator: " "))
                DetailRow(label: "Android", value: [info.androidVersion, info.apiLevel.map { "API \($0)" }].compactMap { $0 }.joined(separator: " · "))
                DetailRow(label: "Screen", value: screen(info))
                DetailRow(label: "RAM", value: info.ram.map { Format.wholeMemory($0) })
                DetailRow(label: "Storage", value: storage(info))
                DetailRow(label: "Battery", value: battery(info.battery))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
            DetailRow(label: "Serial", value: phone.serial, last: true, identifier: true)
        }
        .card()
    }

    private func screen(_ info: PhoneInfo) -> String? {
        guard let size = info.screen else { return nil }
        return "\(size.width) × \(size.height)" + (info.density.map { " · \($0) dpi" } ?? "")
    }

    private func storage(_ info: PhoneInfo) -> String? {
        guard let total = info.storageTotal, let free = info.storageFree else { return nil }
        return "\(Format.diskNumber(free)) GB free of \(Format.wholeDisk(total))"
    }

    private func battery(_ battery: PhoneInfo.Battery?) -> String? {
        guard let battery else { return nil }
        return ["\(battery.level) %", battery.charging ? "charging" : nil, battery.celsius.map { "\(Format.decimal($0)) °C" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct IOSDeviceInspector: View {
    @EnvironmentObject private var store: Store
    let device: IOSDevice

    var body: some View {
        let info = store.iosInfo[device.id]
        let control = store.control(for: device)
        let name = store.name(of: device)
        InspectorPage {
            InspectorHeader(
                preview: DevicePreview(
                    id: device.id,
                    live: control != nil && info?.supports(IOSDeviceInfo.screenshot) == true,
                    tablet: info?.isPad == true,
                    idleText: idleText(info)
                ) {
                    store.refreshPreview(device)
                },
                kicker: info?.isPad == true ? "Connected iPad" : "Connected iPhone",
                title: name,
                subtitle: [info?.model, info?.osVersion.map { "iOS \($0)" }, "USB"].compactMap { $0 }.joined(separator: " · "),
                status: { IOSDeviceStatus(info: info) }
            ) {
                if info?.paired == true, info?.canShareScreen == true, Store.deviceHub != nil {
                    Button("Control in DeviceHub") { store.openInDeviceHub(device) }
                        .buttonStyle(.app(.primary))
                        .help("Xcode’s DeviceHub opens on this device: click View Screen there to tap, type and paste from the Mac.")
                }
                MoreMenu { IOSDeviceMenu(device: device) }
            }

            if let control, let info {
                IOSControlsCard(device: device, control: control, info: info)
                LazyVGrid(columns: cardColumns, spacing: 16) {
                    if info.supports(IOSDeviceInfo.appearance) || info.supports(IOSDeviceInfo.voiceOver) {
                        IOSUICard(device: device, control: control, info: info)
                    }
                    IOSDetailsCard(device: device, info: info)
                }
            } else {
                if let advice = advice(info) { WarningNote(text: advice) }
                if info != nil { IOSDetailsCard(device: device, info: info) }
            }
        }
        .task(id: control?.udid) {
            if control != nil { store.refreshPreview(device) } else if info == nil { store.refreshInfo(device) }
        }
    }

    private func idleText(_ info: IOSDeviceInfo?) -> String {
        guard let info else { return "Connecting…" }
        if !info.paired { return "Not trusted yet" }
        if info.developerMode == false { return "Developer Mode off" }
        if info.preparing { return "Preparing…" }
        return info.connected ? "No screen capture" : "Connecting…"
    }

    private func advice(_ info: IOSDeviceInfo?) -> String? {
        guard let info else { return nil }
        if !info.paired {
            return "Unlock the device and tap Trust on “Trust This Computer?”, then enter its passcode. No prompt? Unplug it and plug it back in."
        }
        if info.developerMode == false {
            return "Turn on Developer Mode in Settings › Privacy & Security on the device to get its screen and controls here."
        }
        if info.preparing {
            return "Xcode prepares the device for development after each iOS update, which can take a few minutes. Keep it unlocked and plugged in: its controls appear here once it’s done."
        }
        return nil
    }
}

struct IOSDeviceMenu: View {
    @EnvironmentObject private var store: Store
    let device: IOSDevice

    var body: some View {
        if store.control(for: device) != nil, store.iosInfo[device.id]?.supports(IOSDeviceInfo.screenshot) == true {
            Button("Screenshot", systemImage: "camera") { store.screenshot(device) }
            Divider()
        }
        if let info = store.iosInfo[device.id], info.paired, info.canShareScreen, Store.deviceHub != nil {
            Button("Control in DeviceHub", systemImage: "hand.tap") { store.openInDeviceHub(device) }
        }
        Button("Copy UDID", systemImage: "doc.on.doc") { store.copyUDID(device) }
    }
}

private struct IOSDeviceStatus: View {
    let info: IOSDeviceInfo?

    var body: some View {
        HStack(spacing: 6) {
            if let info, info.preparing {
                ProgressView().controlSize(.mini)
                Text("Xcode is preparing the device…")
            } else if let info {
                StatusDot(color: info.isControllable ? Theme.good : Theme.moderateText)
                Text(info.paired ? "Connected over USB" : "Waiting for Trust")
                if info.paired, let mode = info.developerMode {
                    Text("· Developer Mode \(mode ? "on" : "off")").foregroundStyle(Theme.textSecondary)
                }
            } else {
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct IOSDetailsCard: View {
    let device: IOSDevice
    let info: IOSDeviceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Details").padding(.bottom, 4)
            if let info {
                DetailRow(label: "Model", value: [info.model, info.productType].compactMap { $0 }.joined(separator: " · "))
                DetailRow(label: info.isPad ? "iPadOS" : "iOS", value: [info.osVersion, info.build].compactMap { $0 }.joined(separator: " · "))
                DetailRow(label: "Storage", value: info.storage.map { Format.wholeDisk($0) })
                DetailRow(label: "Developer Mode", value: info.developerMode.map { $0 ? "On" : "Off" })
            }
            DetailRow(label: "UDID", value: info?.udid ?? device.udid, last: true, identifier: true)
        }
        .card()
    }
}

// MARK: - Shared device parts

private struct InspectorHeader<Preview: View, Status: View, Actions: View>: View {
    let preview: Preview
    let kicker: String
    let title: String
    let subtitle: String
    @ViewBuilder let status: Status
    @ViewBuilder let actions: Actions

    var body: some View {
        // Side by side when the inspector is wide enough, stacked otherwise.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                preview
                text.frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                preview
                text
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(kicker)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            status
            HStack(spacing: 8) { actions }.padding(.top, 4)
        }
    }
}

/// A still of the device's screen, taken on selection and after each button that changes it.
private struct DevicePreview: View {
    @EnvironmentObject private var store: Store
    let id: String
    let live: Bool
    let tablet: Bool
    var idleText = "Not running"
    let refresh: () -> Void

    var body: some View {
        let image = live ? store.previews[id] : nil
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? (tablet ? 1.4 : 0.46)
        let landscape = aspect > 1
        let screenHeight: CGFloat = landscape ? 150 : 216
        let screen = CGSize(width: screenHeight * aspect, height: screenHeight)
        let corner: CGFloat = landscape ? 12 : 17
        Button(action: refresh) {
            ZStack(alignment: .bottom) {
                Theme.deviceScreen
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Text(!live ? idleText : store.previewFailed.contains(id) && !store.previewLoading.contains(id)
                        ? "No screen still · click to retry" : "Capturing…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(light: 0xA49F9B, dark: 0x918C88))
                        .padding(.bottom, 14)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .padding(6)
            .background(Theme.deviceFrame, in: RoundedRectangle(cornerRadius: corner + 5))
            .overlay(alignment: .topTrailing) {
                if store.previewLoading.contains(id) {
                    ProgressView().controlSize(.mini).padding(12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .help(live ? "A still of the screen, updated after each control. Click to refresh." : "")
        .animation(.easeOut(duration: 0.2), value: landscape)
    }
}

private struct StatusLine: View {
    let state: RunState
    let started: Date?
    let memory: UInt64?
    let need: UInt64?

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .running:
                StatusDot(color: Theme.good)
                if let started {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Format.runningFor(since: started, now: context.date))
                    }
                } else {
                    Text("Running")
                }
                if let memory { Text("· \(Format.memory(memory)) memory").foregroundStyle(Theme.textSecondary) }
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Starting…")
            case .booting:
                ProgressView().controlSize(.mini)
                Text("Booting…")
                if let memory { Text("· \(Format.memory(memory)) memory").foregroundStyle(Theme.textSecondary) }
            case .working(let label):
                ProgressView().controlSize(.mini)
                Text(label)
            case .stopped:
                StatusDot(color: Theme.undefined)
                Text("Stopped")
                if let need { Text("· needs ≈ \(Format.memory(need)) RAM").foregroundStyle(Theme.textSecondary) }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// What launching will cost, measured on the device's last run, against what the Mac has free now.
private struct LaunchMemoryCard: View {
    @EnvironmentObject private var store: Store
    let id: String

    var body: some View {
        let need = store.ramNeed(id)
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Memory").padding(.bottom, 4)
            DetailRow(label: "Last run peak", value: need.map(Format.memory) ?? "Not measured yet")
            DetailRow(label: "Available now", value: store.memory.map { Format.memory($0.available) } ?? "…", last: true)
            if let warning = store.memoryWarning(need: need) {
                WarningNote(text: warning).padding(.top, 8)
            } else if need == nil {
                Text("Measured the first time it runs, then shown before every launch.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            }
        }
        .card()
    }
}

struct WarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.moderateText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.moderateBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DangerBar<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider))
    }
}

// MARK: - Maintenance

private struct ImageInspector: View {
    @EnvironmentObject private var store: Store
    let image: SystemImage

    var body: some View {
        let size = store.imageSizes[image.id]
        InspectorPage {
            MaintenanceHeader(
                symbol: image.isEmptyFolder ? "folder" : "shippingbox",
                kicker: image.isEmptyFolder ? "Empty folder" : "Unused system image",
                title: image.title,
                subtitle: image.id
            )
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Details").padding(.bottom, 4)
                DetailRow(label: "API level", value: image.apiLevel.map(String.init))
                DetailRow(label: "ABI", value: image.abi)
                DetailRow(label: "Size", value: image.isEmptyFolder ? "Empty" : size.map(DiskUsage.format) ?? "…")
                DetailRow(label: "Folder", value: (image.dir.path as NSString).abbreviatingWithTildeInPath, last: true)
                Button("Show in Finder") { store.reveal(image) }
                    .buttonStyle(.app(.ghost, size: .small))
                    .padding(.top, 8)
            }
            .card()
            DangerBar(message: image.isEmptyFolder
                ? "It holds no image: nothing is lost."
                : "No emulator boots from it. Deleting frees \(size.map(DiskUsage.format) ?? "its space"); the SDK Manager can download it again.") {
                if store.imageBusy.contains(image.id) {
                    BusyLabel(text: "Deleting…").font(.system(size: 12))
                } else {
                    Button("Delete…") { store.pending = .deleteImage(image) }
                        .buttonStyle(.app(.outlined, size: .small, destructive: true))
                }
            }
        }
    }
}

private struct LeftoverInspector: View {
    @EnvironmentObject private var store: Store
    let item: Leftover

    var body: some View {
        InspectorPage {
            MaintenanceHeader(symbol: "trash", kicker: "Leftover", title: item.title, subtitle: item.explanation)
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(item.urls.count == 1 ? "File" : "\(item.urls.count) items").padding(.bottom, 4)
                ForEach(Array(item.urls.prefix(12).enumerated()), id: \.offset) { index, url in
                    SettingRow(last: index == min(item.urls.count, 12) - 1) {
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if item.urls.count > 12 {
                    Text("and \(item.urls.count - 12) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)
                }
                Button("Show in Finder") { store.reveal(item) }
                    .buttonStyle(.app(.ghost, size: .small))
                    .disabled(item.urls.isEmpty)
                    .padding(.top, 8)
            }
            .card()
            DangerBar(message: "Nothing reads \(item.urls.count == 1 ? "it" : "them"). Deleting frees \(DiskUsage.format(item.size)).") {
                if store.leftoverBusy.contains(item.id) {
                    BusyLabel(text: "Deleting…").font(.system(size: 12))
                } else {
                    Button("Delete…") { store.pending = .deleteLeftover(item) }
                        .buttonStyle(.app(.outlined, size: .small, destructive: true))
                }
            }
        }
    }
}

private struct MaintenanceHeader: View {
    let symbol: String
    let kicker: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 80, height: 80)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(kicker)
                Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3).foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
