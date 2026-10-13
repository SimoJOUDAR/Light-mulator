import AppKit
import Foundation
import ImageIO

enum RunState: Equatable {
    case stopped
    case starting
    case booting
    case running
    case working(String)

    var canLaunch: Bool { self == .stopped }
    var isAlive: Bool { self == .booting || self == .running || self == .working(Store.stopping) }
    var canStop: Bool { self == .booting || self == .running }
    /// Shown under "Running": up, coming up or going down.
    var isActive: Bool { self == .starting || isAlive }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let file: URL?
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum PendingAction: Identifiable {
    case delete(AVD), wipe(AVD), forceKill(AVD)
    case deleteSim(Sim), eraseSim(Sim)
    case deleteImage(SystemImage)
    case deleteLeftover(Leftover), deleteAllLeftovers

    var id: String {
        switch self {
        case .delete(let avd): "delete-\(avd.id)"
        case .wipe(let avd): "wipe-\(avd.id)"
        case .forceKill(let avd): "kill-\(avd.id)"
        case .deleteSim(let sim): "delete-\(sim.id)"
        case .eraseSim(let sim): "erase-\(sim.id)"
        case .deleteImage(let image): "delete-\(image.id)"
        case .deleteLeftover(let item): "delete-\(item.id)"
        case .deleteAllLeftovers: "delete-leftovers"
        }
    }
}

enum SheetKind: Identifiable {
    case details(AVD), edit(AVD), duplicate(AVD)
    case simDetails(Sim), simRename(Sim), simClone(Sim)

    var id: String {
        switch self {
        case .details(let avd): "details-\(avd.id)"
        case .edit(let avd): "edit-\(avd.id)"
        case .duplicate(let avd): "duplicate-\(avd.id)"
        case .simDetails(let sim): "details-\(sim.id)"
        case .simRename(let sim): "rename-\(sim.id)"
        case .simClone(let sim): "clone-\(sim.id)"
        }
    }
}

/// The device plugged in last, which the window switches to.
struct Plugged: Equatable {
    let id = UUID()
    let item: Item
}

struct RunningDevice: Identifiable {
    let id: String
    let name: String
    let memory: UInt64
}

@MainActor
final class Store: ObservableObject {
    nonisolated static let starting = "Starting…"
    nonisolated static let stopping = "Stopping…"
    private static let lastRunKey = "lastRunMemory"
    private static let lastRunStartKey = "lastRunStart"

    @Published private(set) var avds: [AVD] = []
    @Published private(set) var running: [String: RunningInfo] = [:]
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var freeSpace: Int64?
    @Published private(set) var diskTotal: Int64?
    @Published private(set) var busy: [String: String] = [:]
    @Published private var booted: Set<pid_t> = []
    @Published var alert: AlertItem?
    @Published var pending: PendingAction?
    @Published var sheet: SheetKind?
    @Published private(set) var toast: Toast?
    @Published private(set) var recordings: [String: Date] = [:]
    @Published private(set) var sims: [Sim] = []
    @Published private(set) var simRunning: [String: RunningInfo] = [:]
    @Published private(set) var simBusy: [String: String] = [:]
    @Published private var simWaitingBoot: Set<String> = []
    @Published private(set) var runtimes: [SimRuntime] = []
    @Published private(set) var unusedImages: [SystemImage] = []
    @Published private(set) var imageSizes: [String: Int64] = [:]
    @Published private(set) var imageBusy: Set<String> = []
    @Published private(set) var imagesTotalSize: Int64 = 0
    @Published private(set) var leftovers: [Leftover] = []
    @Published private(set) var leftoverBusy: Set<String> = []
    @Published private(set) var memory: MacMemory?
    @Published private(set) var lastRunMemory: [String: UInt64] = [:]
    @Published private(set) var previews: [String: NSImage] = [:]
    @Published private(set) var previewLoading: Set<String> = []
    @Published private(set) var previewFailed: Set<String> = []
    @Published private(set) var connected: [ConnectedDevice] = []
    @Published private(set) var phoneInfo: [String: PhoneInfo] = [:]
    @Published private(set) var mirroring: Set<String> = []
    @Published private(set) var iosDevices: [IOSDevice] = []
    @Published private(set) var iosInfo: [String: IOSDeviceInfo] = [:]
    @Published private(set) var lastPlugged: Plugged?
    @Published private(set) var sharingClipboard: Set<String> = []

    let paths = Paths.resolve()
    private var timer: Timer?
    private var folderStamp: Date?
    private var bootChecks: Set<pid_t> = []
    private var firstSeen: [pid_t: Date] = [:]
    private var launches: [String: Process] = [:]
    private var launchTimes: [String: Date] = [:]
    private var recorders: [String: Process] = [:]
    private var simReloading = false
    private var simsLoaded = false
    private var runtimesFetched: Date?
    private var runPeak: [String: UInt64] = [:]
    /// Boot time of the run each stored peak comes from: a relaunch of this app mid-run must not lower it.
    private var lastRunStart: [String: Double] = [:]
    private var previewAgain: Set<String> = []
    private let tracker = AdbTracker()
    private var startedAdbServer = false
    /// The first list after connecting is what was already plugged in, not an arrival.
    private var adbBaseline = true
    private let usbmux = UsbmuxTracker()
    private var mirrors: [String: Process] = [:]
    private var clipboardSyncs: [String: (process: Process, started: Date)] = [:]
    private var infoRefreshes: [String: Task<Void, Never>] = [:]
    let hasSimulators = SimCtl.path != nil

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.lastRunKey) ?? [:]
        lastRunMemory = stored.compactMapValues { ($0 as? NSNumber)?.uint64Value }
        lastRunStart = (UserDefaults.standard.dictionary(forKey: Self.lastRunStartKey) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        reload()
        trackConnectedDevices(startingServer: true)
        trackIOSDevices()
        schedule(every: 2)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.schedule(every: 2)
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(every: 6) }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipboardSyncs.values.forEach { $0.process.interrupt() } }
        }
    }

    // MARK: State

    func state(of avd: AVD) -> RunState {
        if let label = busy[avd.id], label != Self.starting { return .working(label) }
        if let info = running[avd.id] { return booted.contains(info.pid) ? .running : .booting }
        return busy[avd.id] == Self.starting ? .starting : .stopped
    }

    var androidSize: Int64 { sizes.values.reduce(0, +) }
    var simulatorSize: Int64 { sims.compactMap(\.size).reduce(0, +) }
    var reclaimableImageSize: Int64 { imageSizes.values.reduce(0, +) }
    var leftoverSize: Int64 { leftovers.map(\.size).reduce(0, +) }

    var runningDevices: [RunningDevice] {
        let android = avds.compactMap { avd in
            running[avd.id].map { RunningDevice(id: avd.id, name: avd.displayName, memory: $0.memory) }
        }
        let ios = sims.compactMap { sim in
            simRunning[sim.id].map { RunningDevice(id: sim.id, name: sim.name, memory: $0.memory) }
        }
        return (android + ios).sorted { $0.memory > $1.memory }
    }

    var connectedCount: Int { connected.count + iosDevices.count }

    var activeCount: Int {
        avds.filter { state(of: $0).isActive }.count + sims.filter { state(of: $0).isActive }.count
    }

    /// Peak memory of the device's last run, the best guess of what launching it costs.
    func ramNeed(_ id: String) -> UInt64? { lastRunMemory[id] }

    /// Set when launching would push the Mac into swap.
    func memoryWarning(need: UInt64?) -> String? {
        guard let need, let memory, need > memory.available else { return nil }
        var text = "Needs ≈ \(Format.memory(need)), \(Format.memory(memory.available)) available: macOS will swap."
        if let biggest = runningDevices.first {
            text += " Stopping \(biggest.name) frees \(Format.memory(biggest.memory))."
        }
        return text
    }

    // MARK: Refresh

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = interval * 0.3
    }

    private func poll() {
        if !tracker.isRunning { trackConnectedDevices() }
        if !usbmux.isRunning { trackIOSDevices() }
        if modificationDate(paths.avdHome) != folderStamp { reload() } else { refreshRunning() }
    }

    func reload() {
        folderStamp = modificationDate(paths.avdHome)
        avds = AVDRepository.load(paths)
        refreshRunning()
        refreshSizes()
        refreshImages()
        refreshLeftovers()
        reloadSims()
        refreshRuntimes()
        iosDevices.forEach(refreshInfo)
    }

    private func refreshImages() {
        let paths = paths
        let list = avds
        Task.detached(priority: .utility) {
            let images = SystemImageRepository.unused(paths, avds: list)
            let sizes = Dictionary(images.map { ($0.id, DiskUsage.allocated($0.dir)) }, uniquingKeysWith: +)
            let total = DiskUsage.allocated(paths.sdk.appendingPathComponent("system-images"))
            await MainActor.run {
                if images != self.unusedImages { self.unusedImages = images }
                self.imageSizes = sizes
                self.imagesTotalSize = total
            }
        }
    }

    private func refreshLeftovers() {
        let paths = paths
        let list = avds
        let simulators = simsLoaded || !hasSimulators ? sims : nil
        Task.detached(priority: .utility) {
            let found = LeftoverScanner.scan(paths: paths, avds: list, sims: simulators)
            await MainActor.run {
                if found != self.leftovers { self.leftovers = found }
            }
        }
    }

    private func refreshRuntimes() {
        guard hasSimulators, Date().timeIntervalSince(runtimesFetched ?? .distantPast) > 300 else { return }
        runtimesFetched = Date()
        Task {
            let list = await SimCtl.runtimes()
            if list != runtimes { runtimes = list }
        }
    }

    private func refreshRunning() {
        let withSimulators = hasSimulators
        Task.detached(priority: .utility) {
            let scanned = ProcessScanner.scan()
            let simulators = withSimulators ? ProcessScanner.scanSimulators() : [:]
            let memory = MacMemory.read()
            await self.applyPoll(scanned, simulators, memory)
        }
    }

    /// One main-actor pass per poll, so the window re-renders once, and only when something visible moved.
    private func applyPoll(_ scanned: [String: RunningInfo], _ simulators: [String: RunningInfo], _ reading: MacMemory?) {
        apply(scanned)
        applySimulators(simulators)
        if let reading, memory.map({ !$0.isClose(to: reading) }) ?? true { memory = reading }
        trackPeaks(scanned.merging(simulators) { current, _ in current })
        let ready = Set(connected.filter(\.isReady).map(\.id) + iosDevices.map(\.id))
        let live = previews.filter { running[$0.key] != nil || simRunning[$0.key] != nil || ready.contains($0.key) }
        if live.count != previews.count { previews = live }
    }

    /// Footprints move by a few MB every poll; the window shows tenths of a GB.
    nonisolated static func differs(_ lhs: [String: RunningInfo], _ rhs: [String: RunningInfo]) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return true }
        return lhs.contains { id, info in
            guard let other = rhs[id] else { return true }
            return info.pid != other.pid || info.consolePort != other.consolePort || info.started != other.started
                || max(info.memory, other.memory) - min(info.memory, other.memory) >= MacMemory.visibleStep
        }
    }

    private func apply(_ scanned: [String: RunningInfo]) {
        let changedSet = Set(scanned.keys) != Set(running.keys)
        if Self.differs(scanned, running) { running = scanned }
        let alive = Set(scanned.values.map(\.pid))
        if !booted.isSubset(of: alive) { booted.formIntersection(alive) }
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        for pid in alive where firstSeen[pid] == nil { firstSeen[pid] = Date() }

        var nextBusy = busy
        for (id, info) in scanned {
            if booted.contains(info.pid) {
                if nextBusy[id] == Self.starting { nextBusy[id] = nil }
            } else {
                checkBoot(id: id, info: info)
            }
        }
        for (id, label) in busy where scanned[id] == nil {
            let stale = label == Self.starting && launches[id] == nil
                && Date().timeIntervalSince(launchTimes[id] ?? .distantPast) > 20
            if label == Self.stopping || stale { nextBusy[id] = nil }
        }
        if nextBusy != busy { busy = nextBusy }
        if changedSet { refreshSizes() }
    }

    /// Keeps each device's peak footprint; once it has run 90 s, that peak stands for its next launch.
    private func trackPeaks(_ samples: [String: RunningInfo]) {
        var changed = false
        for (id, info) in samples {
            let peak = max(runPeak[id] ?? 0, info.memory)
            runPeak[id] = peak
            guard let started = info.started, Date().timeIntervalSince(started) > 90 else { continue }
            let stamp = started.timeIntervalSince1970.rounded()
            if lastRunStart[id] != stamp {
                lastRunMemory[id] = peak
                lastRunStart[id] = stamp
                changed = true
            } else if peak > (lastRunMemory[id] ?? 0) + 50_000_000 {
                lastRunMemory[id] = peak
                changed = true
            }
        }
        for id in runPeak.keys where samples[id] == nil { runPeak[id] = nil }
        if changed {
            UserDefaults.standard.set(lastRunMemory.mapValues { NSNumber(value: $0) }, forKey: Self.lastRunKey)
            UserDefaults.standard.set(lastRunStart.mapValues { NSNumber(value: $0) }, forKey: Self.lastRunStartKey)
        }
    }

    private func checkBoot(id: String, info: RunningInfo) {
        guard !bootChecks.contains(info.pid) else { return }
        guard paths.hasAdb else {
            booted.insert(info.pid)
            return
        }
        // The console port comes from the emulator's pid file, written a few seconds after start.
        guard let port = info.consolePort else {
            if Date().timeIntervalSince(firstSeen[info.pid] ?? Date()) > 45 { booted.insert(info.pid) }
            return
        }
        bootChecks.insert(info.pid)
        let adb = paths.adb.path
        Task {
            let result = await Shell.run(adb, ["-s", "emulator-\(port)", "shell", "getprop", "sys.boot_completed"], timeout: 8)
            bootChecks.remove(info.pid)
            guard result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return }
            booted.insert(info.pid)
            if busy[id] == Self.starting { busy[id] = nil }
        }
    }

    private func refreshSizes() {
        let list = avds
        let home = paths.avdHome
        Task.detached(priority: .utility) {
            let computed = Dictionary(list.map { ($0.id, DiskUsage.allocated($0.dir)) }, uniquingKeysWith: +)
            let free = DiskUsage.freeSpace(at: home)
            let total = DiskUsage.totalSpace(at: home)
            await MainActor.run {
                self.sizes = computed
                self.freeSpace = free
                self.diskTotal = total
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Actions

    func launch(_ avd: AVD, coldBoot: Bool = false) {
        guard avd.isUsable, state(of: avd).canLaunch else { return }
        guard paths.hasEmulator else {
            alert = AlertItem(
                title: "Emulator not found",
                message: "Expected at \(paths.emulator.path). Install “Android Emulator” from Android Studio › SDK Manager › SDK Tools."
            )
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let log = Paths.logs.appendingPathComponent("\(avd.id).log")
        fm.createFile(atPath: log.path, contents: nil)

        let process = Process()
        process.executableURL = paths.emulator
        process.arguments = ["-avd", avd.id] + (coldBoot ? ["-no-snapshot-load"] : [])
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_HOME"] = paths.sdk.path
        env["ANDROID_SDK_ROOT"] = paths.sdk.path
        env["ANDROID_AVD_HOME"] = paths.avdHome.path
        process.environment = env
        process.currentDirectoryURL = fm.homeDirectoryForCurrentUser
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        let id = avd.id
        let name = avd.displayName
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.launchEnded(id: id, name: name, status: status, log: log) }
        }
        do {
            try process.run()
            launches[id] = process
            launchTimes[id] = Date()
            busy[id] = Self.starting
        } catch {
            alert = AlertItem(title: "Couldn’t launch \(name)", message: error.localizedDescription)
        }
    }

    private func launchEnded(id: String, name: String, status: Int32, log: URL) {
        launches[id] = nil
        guard busy[id] == Self.starting, status != 0 else { return }
        busy[id] = nil
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).suffix(12).joined(separator: "\n")
        alert = AlertItem(
            title: "\(name) failed to start (exit \(status))",
            message: lines.isEmpty ? "No output. Full log: \(log.path)" : "\(lines)\n\nFull log: \(log.path)"
        )
    }

    func stop(_ avd: AVD) {
        guard let info = ProcessScanner.scan()[avd.id] ?? running[avd.id] else { return }
        busy[avd.id] = Self.stopping
        let adb = paths.hasAdb ? paths.adb.path : nil
        Task {
            if let port = info.consolePort, let adb {
                _ = await Shell.run(adb, ["-s", "emulator-\(port)", "emu", "kill"], timeout: 10)
            } else {
                kill(info.pid, SIGTERM)
            }
            if await Self.waitForExit(info.pid, seconds: 20) { return finishStop(avd.id, pid: info.pid) }
            kill(info.pid, SIGTERM)
            if await Self.waitForExit(info.pid, seconds: 10) { return finishStop(avd.id, pid: info.pid) }
            busy[avd.id] = nil
            alert = AlertItem(
                title: "\(avd.displayName) is still running",
                message: "It didn’t shut down within 30 s. Use ⋯ › Force Kill to stop it now (its quick-boot state won’t be saved)."
            )
        }
    }

    func stopAll() {
        for avd in avds where state(of: avd).canStop { stop(avd) }
        for sim in sims where state(of: sim).canStop { stop(sim) }
    }

    /// The emulator window belongs to its qemu process: bring that app forward.
    func showWindow(_ avd: AVD) {
        guard let pid = running[avd.id]?.pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    private func forceKill(_ avd: AVD) {
        guard let info = running[avd.id] else { return }
        busy[avd.id] = Self.stopping
        kill(info.pid, SIGKILL)
        Task {
            _ = await Self.waitForExit(info.pid, seconds: 5)
            finishStop(avd.id, pid: info.pid)
        }
    }

    private func finishStop(_ id: String, pid: pid_t) {
        running[id] = nil
        booted.remove(pid)
        busy[id] = nil
        refreshRunning()
        refreshSizes()
    }

    nonisolated private static func waitForExit(_ pid: pid_t, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !ProcessScanner.isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !ProcessScanner.isAlive(pid)
    }

    func confirm(_ action: PendingAction) {
        switch action {
        case .delete(let avd):
            let paths = paths
            runFileJob(avd, label: "Deleting…") { try AVDRepository.delete(avd, paths: paths) }
        case .wipe(let avd): runFileJob(avd, label: "Wiping…") { try AVDRepository.wipe(avd) }
        case .forceKill(let avd): forceKill(avd)
        case .deleteSim(let sim):
            // simctl keeps the device's logs after deleting it.
            let logs = LeftoverScanner.simulatorLogs.appendingPathComponent(sim.id)
            runSimJob(sim, "Deleting…", ["delete", sim.id]) { try? FileManager.default.removeItem(at: logs) }
        case .eraseSim(let sim): runSimJob(sim, "Erasing…", ["erase", sim.id])
        case .deleteImage(let image): delete(image)
        case .deleteLeftover(let item): delete(item)
        case .deleteAllLeftovers: leftovers.filter { !leftoverBusy.contains($0.id) }.forEach(delete)
        }
    }

    func duplicate(_ avd: AVD, as name: String) {
        let paths = paths
        runFileJob(avd, label: "Duplicating…") { _ = try AVDRepository.duplicate(avd, name: name, paths: paths) }
    }

    func saveEdits(_ avd: AVD, _ updates: [String: String]) {
        guard state(of: avd) == .stopped else {
            alert = AlertItem(title: "Stop \(avd.displayName) first", message: "The emulator rewrites config.ini while it runs.")
            return
        }
        do {
            try INI.update(avd.configURL, with: updates)
            reload()
        } catch {
            alert = AlertItem(title: "Couldn’t save \(avd.displayName)", message: error.localizedDescription)
        }
    }

    private func runFileJob(_ avd: AVD, label: String, _ job: @escaping @Sendable () throws -> Void) {
        guard state(of: avd) == .stopped else {
            alert = AlertItem(title: "Stop \(avd.displayName) first", message: "This can’t run while the emulator is running.")
            return
        }
        busy[avd.id] = label
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do { try job(); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                self.busy[avd.id] = nil
                if let failure { self.alert = AlertItem(title: "\(label.dropLast()) failed", message: failure) }
                self.reload()
            }
        }
    }

    // MARK: Running device

    func device(for avd: AVD) -> DeviceShell? {
        guard paths.hasAdb, let port = running[avd.id]?.consolePort else { return nil }
        return DeviceShell(adb: paths.adb.path, serial: "emulator-\(port)")
    }

    func screenshot(_ device: DeviceShell, name: String) {
        let file = Self.desktopFile("Screenshot", name, "png")
        Task {
            guard await device.screenshot(to: file) else {
                try? FileManager.default.removeItem(at: file)
                return showToast("Couldn’t take a screenshot of \(name)")
            }
            if let image = NSImage(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            showToast("Screenshot saved to the Desktop and copied", file: file)
        }
    }

    func toggleRecording(_ device: DeviceShell, id: String, name: String) {
        if recorders[id] != nil {
            Task { await device.shell("pkill -INT screenrecord") }
            return
        }
        let remote = "/sdcard/emulator-manager-\(AVDRepository.sanitizedID(id)).mp4"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: device.adb)
        process.arguments = ["-s", device.serial, "shell", "screenrecord", "--bit-rate", "4000000", "--time-limit", "180", remote]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in await self?.saveRecording(id: id, device: device, remote: remote, name: name) }
        }
        do {
            try process.run()
            recorders[id] = process
            recordings[id] = Date()
        } catch {
            showToast("Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    private func saveRecording(id: String, device: DeviceShell, remote: String, name: String) async {
        recorders[id] = nil
        recordings[id] = nil
        let file = Self.desktopFile("Recording", name, "mp4")
        let pulled = await Shell.run(device.adb, ["-s", device.serial, "pull", remote, file.path], timeout: 120)
        await device.shell("rm -f \(remote)")
        if pulled.status == 0 {
            showToast("Recording saved to the Desktop", file: file)
        } else {
            showToast("The recording of \(name) was lost (\(device.isEmulator ? "emulator closed" : "device unplugged")?)")
        }
    }

    private static func desktopFile(_ kind: String, _ device: String, _ ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = AVDRepository.sanitizedID(device)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/\(kind)_\(name)_\(formatter.string(from: Date())).\(ext)")
    }

    func showToast(_ message: String, file: URL? = nil) {
        let toast = Toast(message: message, file: file)
        self.toast = toast
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.toast == toast { self.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: Preview

    /// One screenshot, scaled down: a still of the screen, refreshed on demand rather than streamed.
    func refreshPreview(_ id: String, _ device: DeviceShell) {
        capturePreview(id) { await device.screenshot(to: $0) }
    }

    func refreshPreview(_ sim: Sim) {
        guard simRunning[sim.id] != nil else { return }
        let device = SimDevice(udid: sim.id)
        capturePreview(sim.id) { await device.screenshot(to: $0) }
    }

    /// After a button that changes the screen, once the device has had time to draw it.
    func refreshPreviewSoon(_ id: String, _ device: DeviceShell, delay: Double = 0.8) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            refreshPreview(id, device)
        }
    }

    private func capturePreview(_ id: String, _ capture: @escaping (URL) async -> Bool) {
        guard !previewLoading.contains(id) else {
            previewAgain.insert(id)
            return
        }
        previewLoading.insert(id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        Task {
            let captured = await capture(file)
            let image = captured ? await Task.detached(priority: .utility) { Self.thumbnail(file) }.value : nil
            try? FileManager.default.removeItem(at: file)
            previewLoading.remove(id)
            if let image {
                previews[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                previewFailed.remove(id)
            } else if previews[id] == nil {
                previewFailed.insert(id)
            }
            if previewAgain.remove(id) != nil { capturePreview(id, capture) }
        }
    }

    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 560,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: System images & leftovers

    private func delete(_ image: SystemImage) {
        guard !SystemImageRepository.isUsed(image, by: AVDRepository.load(paths)) else {
            alert = AlertItem(title: "This image is in use", message: "An emulator boots from \(image.id) now. Delete that emulator first.")
            reload()
            return
        }
        imageBusy.insert(image.id)
        let paths = paths
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do { try SystemImageRepository.delete(image, paths: paths); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                self.imageBusy.remove(image.id)
                if let failure { self.alert = AlertItem(title: "Couldn’t delete \(image.title)", message: failure) }
                self.refreshImages()
                self.refreshSizes()
            }
        }
    }

    private func delete(_ item: Leftover) {
        leftoverBusy.insert(item.id)
        let paths = paths
        Task.detached(priority: .userInitiated) {
            let failure = await Self.remove(item, paths: paths)
            await MainActor.run {
                self.leftoverBusy.remove(item.id)
                if let failure { self.alert = AlertItem(title: "Couldn’t delete \(item.title)", message: failure) }
                self.reload()
            }
        }
    }

    nonisolated private static func remove(_ item: Leftover, paths: Paths) async -> String? {
        do {
            switch item.kind {
            case .brokenAVD:
                if let avd = item.avd { try AVDRepository.delete(avd, paths: paths) }
            case .unavailableSims:
                let result = await SimCtl.run(["delete", "unavailable"], timeout: 120)
                return result.status == 0 ? nil : result.output
            case .emulatorLog, .launchLog, .simulatorLogs:
                try LeftoverScanner.delete(item, paths: paths)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func reveal(_ image: SystemImage) {
        NSWorkspace.shared.activateFileViewerSelecting([image.dir])
    }

    func reveal(_ item: Leftover) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(item.urls.prefix(20)))
    }

    func reveal(_ avd: AVD) {
        let target = FileManager.default.fileExists(atPath: avd.dir.path) ? avd.dir : (avd.ini ?? paths.avdHome)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openAVDFolder() {
        NSWorkspace.shared.open(paths.avdHome)
    }

    func openLogs() {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.logs)
    }

    func openConfig(_ avd: AVD) {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([avd.configURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - iOS Simulators

extension Store {
    func state(of sim: Sim) -> RunState {
        if let label = simBusy[sim.id], label != Self.starting { return .working(label) }
        if simRunning[sim.id] != nil {
            return sim.state == "Booted" && !simWaitingBoot.contains(sim.id) ? .running : .booting
        }
        return simBusy[sim.id] == Self.starting ? .starting : .stopped
    }

    func reloadSims() {
        guard hasSimulators, !simReloading else { return }
        simReloading = true
        Task {
            let list = await SimCtl.list()
            simReloading = false
            guard let list else { return }
            let changed = !simsLoaded || list != sims
            simsLoaded = true
            if list != sims { sims = list }
            if changed { refreshLeftovers() }
        }
    }

    fileprivate func applySimulators(_ scanned: [String: RunningInfo]) {
        let changedSet = Set(scanned.keys) != Set(simRunning.keys)
        if Self.differs(scanned, simRunning) { simRunning = scanned }
        let transitional = sims.contains { $0.state == "Booting" || $0.state == "Shutting Down" }
            || sims.contains { scanned[$0.id] != nil && $0.state != "Booted" }
        if changedSet || transitional { reloadSims() }
        let stale = simBusy.filter { $0.value == Self.stopping && scanned[$0.key] == nil }.keys
        if !stale.isEmpty { stale.forEach { simBusy[$0] = nil } }
    }

    func launch(_ sim: Sim) {
        guard sim.isUsable, state(of: sim).canLaunch else { return }
        simBusy[sim.id] = Self.starting
        simWaitingBoot.insert(sim.id)
        Task {
            let boot = await SimCtl.run(["boot", sim.id], timeout: 120)
            guard boot.status == 0 || boot.output.contains("current state: Booted") else {
                simBusy[sim.id] = nil
                simWaitingBoot.remove(sim.id)
                alert = AlertItem(title: "\(sim.name) failed to boot", message: boot.output)
                return
            }
            SimCtl.showWindow(sim.id)
            reloadSims()
            await SimCtl.run(["bootstatus", sim.id], timeout: 300)
            simWaitingBoot.remove(sim.id)
            if simBusy[sim.id] == Self.starting { simBusy[sim.id] = nil }
            reloadSims()
        }
    }

    func stop(_ sim: Sim) {
        simBusy[sim.id] = Self.stopping
        recorders[sim.id]?.interrupt()
        Task {
            let result = await SimCtl.run(["shutdown", sim.id], timeout: 90)
            simBusy[sim.id] = nil
            simWaitingBoot.remove(sim.id)
            if result.status != 0 && !result.output.contains("current state: Shutdown") {
                alert = AlertItem(title: "Couldn’t shut down \(sim.name)", message: result.output)
            }
            let stillBooted = await Task.detached { ProcessScanner.scanSimulators() }.value
            simRunning = stillBooted
            if stillBooted.isEmpty { SimCtl.quitWindowAppIfIdle() }
            reloadSims()
        }
    }

    func clone(_ sim: Sim, as name: String) {
        runSimJob(sim, "Duplicating…", ["clone", sim.id, name])
    }

    func rename(_ sim: Sim, to name: String) {
        runSimJob(sim, "Renaming…", ["rename", sim.id, name], requiresStopped: false)
    }

    fileprivate func runSimJob(
        _ sim: Sim,
        _ label: String,
        _ arguments: [String],
        requiresStopped: Bool = true,
        onSuccess: (() -> Void)? = nil
    ) {
        guard !requiresStopped || state(of: sim) == .stopped else {
            alert = AlertItem(title: "Shut down \(sim.name) first", message: "This can’t run while the simulator is booted.")
            return
        }
        simBusy[sim.id] = label
        Task {
            let result = await SimCtl.run(arguments, timeout: 300)
            simBusy[sim.id] = nil
            if result.status != 0 {
                alert = AlertItem(title: "\(label.dropLast()) \(sim.name) failed", message: result.output)
            } else {
                onSuccess?()
            }
            reloadSims()
        }
    }

    func screenshot(_ sim: Sim) {
        let file = Self.desktopFile("Screenshot", sim.name, "png")
        Task {
            guard await SimDevice(udid: sim.id).screenshot(to: file) else {
                try? FileManager.default.removeItem(at: file)
                return showToast("Couldn’t take a screenshot of \(sim.name)")
            }
            if let image = NSImage(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            showToast("Screenshot saved to the Desktop and copied", file: file)
        }
    }

    func toggleRecording(_ sim: Sim) {
        if let recorder = recorders[sim.id] {
            recorder.interrupt()
            return
        }
        let file = Self.desktopFile("Recording", sim.name, "mov")
        guard let process = SimDevice(udid: sim.id).recordingProcess(to: file) else { return }
        let id = sim.id
        let name = sim.name
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.recordingEnded(id: id, name: name, file: file) }
        }
        do {
            try process.run()
            recorders[id] = process
            recordings[id] = Date()
        } catch {
            showToast("Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    private func recordingEnded(id: String, name: String, file: URL) {
        recorders[id] = nil
        recordings[id] = nil
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 {
            showToast("Recording saved to the Desktop", file: file)
        } else {
            try? FileManager.default.removeItem(at: file)
            showToast("The recording of \(name) was lost (simulator shut down?)")
        }
    }

    func reveal(_ sim: Sim) {
        guard let folder = sim.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Connected devices

extension Store {
    /// The list arrives from the adb server whenever it changes; a lost connection is retried on the next poll.
    fileprivate func trackConnectedDevices(startingServer: Bool = false) {
        guard paths.hasAdb else { return }
        adbBaseline = true
        let started = tracker.start(
            onChange: { [weak self] list in Task { @MainActor in self?.applyConnected(list) } },
            onEnd: { [weak self] in
                Task { @MainActor in
                    self?.applyConnected([])
                    self?.adbBaseline = true
                }
            }
        )
        // Android Studio usually runs the server already; otherwise start it once, as `adb devices` would.
        guard !started, startingServer, !startedAdbServer else { return }
        startedAdbServer = true
        let adb = paths.adb.path
        Task {
            _ = await Shell.run(adb, ["start-server"], timeout: 15)
            trackConnectedDevices()
        }
    }

    private func applyConnected(_ list: [ConnectedDevice]) {
        let wasReady = Set(connected.filter(\.isReady).map(\.id))
        let known = Set(connected.map(\.id))
        let arrived = adbBaseline ? nil : list.last { !known.contains($0.id) }
        adbBaseline = false
        if list != connected { connected = list }
        if let arrived { lastPlugged = Plugged(item: .phone(arrived.id)) }
        for phone in list where phone.isReady && (!wasReady.contains(phone.id) || phoneInfo[phone.id] == nil) {
            refreshInfo(phone)
        }
        let present = Set(list.map(\.id))
        if phoneInfo.keys.contains(where: { !present.contains($0) }) {
            phoneInfo = phoneInfo.filter { present.contains($0.key) }
        }
    }

    private func refreshInfo(_ phone: ConnectedDevice) {
        guard let device = device(for: phone) else { return }
        Task {
            let info = await device.readInfo()
            guard connected.contains(where: { $0.id == phone.id && $0.isReady }), phoneInfo[phone.id] != info else { return }
            phoneInfo[phone.id] = info
        }
    }

    func refreshBattery(_ phone: ConnectedDevice) {
        guard let device = device(for: phone), phoneInfo[phone.id] != nil else { return }
        Task {
            guard let battery = await device.readBattery(), phoneInfo[phone.id]?.battery != battery else { return }
            phoneInfo[phone.id]?.battery = battery
        }
    }

    func device(for phone: ConnectedDevice) -> DeviceShell? {
        guard paths.hasAdb, phone.isReady else { return nil }
        return DeviceShell(adb: paths.adb.path, serial: phone.serial)
    }

    func name(of phone: ConnectedDevice) -> String {
        phoneInfo[phone.id]?.name ?? phone.model ?? phone.serial
    }

    /// A live window of the device through scrcpy; a second click brings that window forward.
    func mirror(_ phone: ConnectedDevice) {
        if let process = mirrors[phone.id], process.isRunning {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateAllWindows])
            return
        }
        guard let scrcpy = Mirror.path else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let log = Paths.logs.appendingPathComponent("mirror-\(AVDRepository.sanitizedID(phone.serial)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpy)
        process.arguments = ["-s", phone.serial, "--no-audio", "--window-title", name(of: phone)]
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = paths.adb.path
        process.environment = env
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        let id = phone.id
        let name = name(of: phone)
        let started = Date()
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.mirrorEnded(id: id, name: name, status: status, ranFor: Date().timeIntervalSince(started), log: log) }
        }
        do {
            try process.run()
            mirrors[id] = process
            mirroring.insert(id)
        } catch {
            alert = AlertItem(title: "Couldn’t mirror \(name)", message: error.localizedDescription)
        }
    }

    private func mirrorEnded(id: String, name: String, status: Int32, ranFor: TimeInterval, log: URL) {
        mirrors[id] = nil
        mirroring.remove(id)
        guard status != 0, ranFor < 10 else { return }
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
        alert = AlertItem(title: "Couldn’t mirror \(name)", message: lines.isEmpty ? "scrcpy exited with \(status)." : lines)
    }

    func stopMirroring(_ phone: ConnectedDevice) {
        mirrors[phone.id]?.terminate()
    }

    /// A `.command` file opens in Terminal without asking for Automation access.
    func openShell(_ phone: ConnectedDevice) {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("adb-shell-\(AVDRepository.sanitizedID(phone.serial)).command")
        let body = "#!/bin/sh\nclear\nexec '\(paths.adb.path)' -s '\(phone.serial)' shell\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    func copySerial(_ phone: ConnectedDevice) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phone.serial, forType: .string)
        showToast("Serial number copied")
    }

    func disconnect(_ phone: ConnectedDevice) {
        let adb = paths.adb.path
        Task { _ = await Shell.run(adb, ["disconnect", phone.serial], timeout: 10) }
    }
}

// MARK: - Connected iPhones and iPads

extension Store {
    fileprivate func trackIOSDevices() {
        guard UsbmuxTracker.isAvailable, DeviceCtl.path != nil else { return }
        _ = usbmux.start(
            onChange: { [weak self] list, initial, trusted in
                Task { @MainActor in self?.applyIOSDevices(list, initial: initial, trusted: trusted) }
            },
            onEnd: { [weak self] in Task { @MainActor in self?.applyIOSDevices([], initial: true, trusted: nil) } }
        )
    }

    private func applyIOSDevices(_ list: [IOSDevice], initial: Bool, trusted: String?) {
        let known = Set(iosDevices.map(\.id))
        let arrived = list.filter { !known.contains($0.id) }
        if list != iosDevices { iosDevices = list }
        arrived.forEach { refreshInfo($0) }
        if let trusted, let device = list.first(where: { $0.id == trusted }) { refreshInfo(device) }
        if !initial, let last = arrived.last { lastPlugged = Plugged(item: .iosDevice(last.id)) }
        let present = Set(list.map(\.id))
        if iosInfo.keys.contains(where: { !present.contains($0) }) {
            iosInfo = iosInfo.filter { present.contains($0.key) }
        }
        for id in sharingClipboard where !present.contains(id) { stopSharingClipboard(id) }
        for id in infoRefreshes.keys where !present.contains(id) { infoRefreshes.removeValue(forKey: id)?.cancel() }
    }

    /// CoreDevice can take a few seconds to see a device usbmuxd just reported, and minutes to prepare it after an iOS update.
    func refreshInfo(_ device: IOSDevice) {
        infoRefreshes[device.id]?.cancel()
        infoRefreshes[device.id] = Task {
            for delay in [0.0, 2, 4, 8, 15] + Array(repeating: 30, count: 20) {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, iosDevices.contains(device) else { return }
                if let info = await DeviceCtl.info(for: device.udid), !Task.isCancelled {
                    if iosInfo[device.id] != info { iosInfo[device.id] = info }
                    // An untrusted device is fetched again when usbmuxd reports it paired.
                    if info.connected || !info.paired { break }
                }
            }
            infoRefreshes[device.id] = nil
        }
    }

    func control(for device: IOSDevice) -> IOSDeviceControl? {
        guard let info = iosInfo[device.id], info.isControllable else { return nil }
        return IOSDeviceControl(udid: info.udid)
    }

    func name(of device: IOSDevice) -> String {
        iosInfo[device.id]?.name ?? iosInfo[device.id]?.model ?? "iPhone"
    }

    func refreshPreview(_ device: IOSDevice) {
        guard iosInfo[device.id]?.supports(IOSDeviceInfo.screenshot) == true, let control = control(for: device) else { return }
        capturePreview(device.id) { await control.screenshot(to: $0) }
    }

    func refreshPreviewSoon(_ device: IOSDevice, delay: Double = 1.2) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            refreshPreview(device)
        }
    }

    func screenshot(_ device: IOSDevice) {
        guard let control = control(for: device) else { return }
        let name = name(of: device)
        let file = Self.desktopFile("Screenshot", name, "png")
        Task {
            guard await control.screenshot(to: file) else {
                try? FileManager.default.removeItem(at: file)
                return showToast("Couldn’t take a screenshot of \(name)")
            }
            if let image = NSImage(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            showToast("Screenshot saved to the Desktop and copied", file: file)
        }
    }

    func toggleRecording(_ device: IOSDevice) {
        if let recorder = recorders[device.id] {
            recorder.interrupt()
            return
        }
        let name = name(of: device)
        let file = Self.desktopFile("Recording", name, "mp4")
        guard let process = control(for: device)?.recordingProcess(to: file) else { return }
        let id = device.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.recordingEnded(id: id, name: name, file: file) }
        }
        do {
            try process.run()
            recorders[id] = process
            recordings[id] = Date()
        } catch {
            showToast("Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    func copyUDID(_ device: IOSDevice) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(iosInfo[device.id]?.udid ?? device.udid, forType: .string)
        showToast("UDID copied")
    }
}

// MARK: - Shared clipboard and DeviceHub

extension Store {
    func toggleSharedClipboard(_ device: IOSDevice) {
        if sharingClipboard.contains(device.id) {
            stopSharingClipboard(device.id)
        } else {
            shareClipboard(device)
        }
    }

    /// `devicectl`'s two-way pasteboard sync; it starts by sending the Mac's clipboard to the device.
    fileprivate func shareClipboard(_ device: IOSDevice) {
        guard clipboardSyncs[device.id] == nil, let udid = iosInfo[device.id]?.udid, let path = DeviceCtl.path else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "device", "pasteboard", "sync-with-host", "--device", udid,
            "--session-timeout", "3500", "--timeout", "3600", "--quiet",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.sharedClipboardEnded(device) }
        }
        do {
            try process.run()
            clipboardSyncs[device.id] = (process, Date())
            sharingClipboard.insert(device.id)
        } catch {
            showToast("Couldn’t share the clipboard: \(error.localizedDescription)")
        }
    }

    /// A session lasts an hour at most: it is renewed while wanted, unless it failed right away.
    private func sharedClipboardEnded(_ device: IOSDevice) {
        let started = clipboardSyncs.removeValue(forKey: device.id)?.started ?? .distantPast
        guard sharingClipboard.contains(device.id) else { return }
        if iosDevices.contains(device), Date().timeIntervalSince(started) > 10 {
            shareClipboard(device)
        } else {
            sharingClipboard.remove(device.id)
            if iosDevices.contains(device) { showToast("The clipboard stopped being shared with \(name(of: device))") }
        }
    }

    fileprivate func stopSharingClipboard(_ id: String) {
        sharingClipboard.remove(id)
        clipboardSyncs[id]?.process.interrupt()
    }

    static let deviceHub = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Devices")

    /// Xcode 27's DeviceHub, opened on this device: View Screen there gives touch, keyboard and the clipboard (iOS 27 and later).
    func openInDeviceHub(_ device: IOSDevice) {
        guard let url = URL(string: "devices://device/open?id=\(iosInfo[device.id]?.udid ?? device.udid)") else { return }
        NSWorkspace.shared.open(url)
    }
}
