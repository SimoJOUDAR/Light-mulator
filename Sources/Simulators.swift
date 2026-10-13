import AppKit
import Foundation

struct Sim: Identifiable, Hashable {
    let id: String
    let name: String
    let runtime: String
    let deviceType: String
    let state: String
    let problem: String?
    let dataPath: URL?
    let size: Int64?

    var isUsable: Bool { problem == nil }
    var folder: URL? { dataPath?.deletingLastPathComponent() }

    var model: String { deviceType.replacingOccurrences(of: "-", with: " ") }
    var family: Int { name.hasPrefix("iPhone") ? 0 : name.hasPrefix("iPad") ? 1 : 2 }

    var symbol: String {
        let type = deviceType.lowercased()
        if type.contains("ipad") { return "ipad.landscape" }
        if type.contains("watch") { return "applewatch" }
        if type.contains("tv") { return "appletv" }
        if type.contains("vision") { return "visionpro" }
        return "iphone"
    }
}

enum Xcrun {
    /// Resolved once: running a tool directly (not through `xcrun`) lets SIGINT reach it, which stops a recording.
    static func find(_ tool: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", tool]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !found.isEmpty ? found : nil
    }
}

enum SimCtl {
    static let path = Xcrun.find("simctl")

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 60) async -> (status: Int32, output: String) {
        guard let path else { return (-1, "Xcode’s simctl was not found.") }
        return await Shell.run(path, arguments, timeout: timeout)
    }

    static func list() async -> [Sim]? {
        let result = await run(["list", "devices", "--json"], timeout: 30)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DeviceList.self, from: data) else { return nil }
        return decoded.devices.flatMap { runtimeKey, devices in
            devices.map { device in
                Sim(
                    id: device.udid,
                    name: device.name,
                    runtime: runtimeName(runtimeKey),
                    deviceType: device.deviceTypeIdentifier?.components(separatedBy: ".").last ?? "",
                    state: device.state,
                    problem: device.isAvailable == false
                        ? "Runtime not installed\(device.availabilityError.map { " — \($0)" } ?? "")"
                        : nil,
                    dataPath: device.dataPath.map { URL(fileURLWithPath: $0) },
                    size: device.dataPathSize
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.runtime != rhs.runtime { return lhs.runtime.localizedStandardCompare(rhs.runtime) == .orderedDescending }
            if lhs.family != rhs.family { return lhs.family < rhs.family }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Installed runtimes with their size: the biggest simulator cost, shared by every device on it.
    static func runtimes() async -> [SimRuntime] {
        let output = await run(["runtime", "list", "-j"], timeout: 30).output
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: [String: Any]]
        else { return [] }
        return json.values.compactMap { runtime in
            guard let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value,
                  let identifier = runtime["runtimeIdentifier"] as? String else { return nil }
            return SimRuntime(name: runtimeName(identifier), size: size)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
    private static func runtimeName(_ key: String) -> String {
        let parts = (key.components(separatedBy: "SimRuntime.").last ?? key).split(separator: "-")
        guard let platform = parts.first else { return key }
        let name = platform == "xrOS" ? "visionOS" : String(platform)
        return parts.count > 1 ? "\(name) \(parts.dropFirst().joined(separator: "."))" : name
    }

    private static let simulatorApp = "com.apple.iphonesimulator"
    /// Xcode 27 replaced Simulator.app with DeviceHub, which has no launch argument to pick a device.
    private static let deviceHub = "com.apple.dt.Devices"
    @MainActor private static var openedApp: String?

    static var windowAppName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: simulatorApp) == nil ? "DeviceHub" : "Simulator"
    }

    @MainActor
    static func showWindow(_ udid: String) {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        if let simulator = workspace.urlForApplication(withBundleIdentifier: simulatorApp) {
            configuration.arguments = ["-CurrentDeviceUDID", udid]
            workspace.openApplication(at: simulator, configuration: configuration)
            openedApp = simulatorApp
        } else if let hub = workspace.urlForApplication(withBundleIdentifier: deviceHub) {
            workspace.openApplication(at: hub, configuration: configuration)
            openedApp = deviceHub
        }
    }

    /// The window app keeps ~100 MB alive with no device left: quit it once the last one is shut down, if we opened it.
    @MainActor
    static func quitWindowAppIfIdle() {
        guard let openedApp else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: openedApp).forEach { $0.terminate() }
        self.openedApp = nil
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let availabilityError: String?
        let dataPath: String?
        let dataPathSize: Int64?
        let deviceTypeIdentifier: String?
    }
}

/// The toolbar for one booted simulator, through `simctl`.
struct SimDevice: Sendable {
    let udid: String

    static let contentSizes: [(id: String, label: String)] = [
        ("extra-small", "XS"), ("small", "S"), ("medium", "M"), ("large", "Default"), ("extra-large", "XL"),
        ("extra-extra-large", "XXL"), ("extra-extra-extra-large", "XXXL"), ("accessibility-medium", "AX1"),
        ("accessibility-large", "AX2"), ("accessibility-extra-large", "AX3"),
        ("accessibility-extra-extra-large", "AX4"), ("accessibility-extra-extra-extra-large", "AX5"),
    ]

    static let languages: [(id: String, name: String, arguments: [String])] = [
        ("", "System language", []),
        ("en", "English", ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]),
        ("fr", "Français", ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]),
        ("de", "Deutsch", ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]),
        ("es", "Español", ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]),
        ("it", "Italiano", ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]),
        ("pt-BR", "Português (Brasil)", ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]),
        ("nl", "Nederlands", ["-AppleLanguages", "(nl)", "-AppleLocale", "nl_NL"]),
        ("ja", "日本語", ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]),
        ("ko", "한국어", ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]),
        ("zh-Hans", "中文 (简体)", ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]),
        ("ar", "العربية (RTL)", ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_EG"]),
        ("double", "Pseudo — double length", ["-NSDoubleLocalizedStrings", "YES"]),
        ("rtl", "Pseudo — right to left", ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]),
    ]

    func screenshot(to url: URL) async -> Bool {
        let result = await SimCtl.run(["io", udid, "screenshot", "--type=png", url.path], timeout: 30)
        return result.status == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    func recordingProcess(to url: URL) -> Process? {
        guard let path = SimCtl.path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["io", udid, "recordVideo", "--codec=h264", "--force", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func readUI() async -> SimUISettings {
        async let appearance = SimCtl.run(["ui", udid, "appearance"], timeout: 10)
        async let contentSize = SimCtl.run(["ui", udid, "content_size"], timeout: 10)
        async let contrast = SimCtl.run(["ui", udid, "increase_contrast"], timeout: 10)
        async let statusBar = SimCtl.run(["status_bar", udid, "list"], timeout: 10)
        async let apps = userApps()
        let bar = await statusBar.output
        return SimUISettings(
            dark: (await appearance.output).trimmingCharacters(in: .whitespacesAndNewlines) == "dark",
            contentSize: (await contentSize.output).trimmingCharacters(in: .whitespacesAndNewlines),
            increaseContrast: (await contrast.output).trimmingCharacters(in: .whitespacesAndNewlines) == "enabled",
            cleanStatusBar: bar.contains("9:41"),
            apps: await apps
        )
    }

    func setDark(_ on: Bool) async {
        await SimCtl.run(["ui", udid, "appearance", on ? "dark" : "light"], timeout: 10)
    }

    func setContentSize(_ size: String) async {
        await SimCtl.run(["ui", udid, "content_size", size], timeout: 10)
    }

    func setIncreaseContrast(_ on: Bool) async {
        await SimCtl.run(["ui", udid, "increase_contrast", on ? "enabled" : "disabled"], timeout: 10)
    }

    /// Apple's marketing status bar: 9:41, full battery, full signal.
    func setCleanStatusBar(_ on: Bool) async {
        if on {
            await SimCtl.run([
                "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
                "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                "--batteryState", "charged", "--batteryLevel", "100",
            ], timeout: 10)
        } else {
            await SimCtl.run(["status_bar", udid, "clear"], timeout: 10)
        }
    }

    func userApps() async -> [(id: String, name: String)] {
        let output = await SimCtl.run(["listapps", udid], timeout: 20).output
        guard let start = output.firstIndex(of: "{"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(output[start...].utf8), format: nil),
              let apps = plist as? [String: [String: Any]] else { return [] }
        return apps.compactMap { id, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            return (id, info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Launch arguments win over the system language for that launch, like an Xcode scheme's "App Language".
    func relaunch(_ bundle: String, language: String) async -> String? {
        let arguments = Self.languages.first { $0.id == language }?.arguments ?? []
        await SimCtl.run(["terminate", udid, bundle], timeout: 10)
        let result = await SimCtl.run(["launch", udid, bundle] + arguments, timeout: 30)
        return result.status == 0 ? nil : result.output
    }

    func openURL(_ url: String) async -> String? {
        let result = await SimCtl.run(["openurl", udid, url], timeout: 20)
        return result.status == 0 ? nil : result.output
    }
}

struct SimRuntime: Hashable, Sendable {
    let name: String
    let size: Int64
}

struct SimUISettings {
    var dark: Bool
    var contentSize: String
    var increaseContrast: Bool
    var cleanStatusBar: Bool
    let apps: [(id: String, name: String)]
}
