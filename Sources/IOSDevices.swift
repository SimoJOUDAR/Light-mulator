import Darwin
import Foundation

/// An iPhone or iPad plugged in over USB, as usbmuxd reports it.
struct IOSDevice: Identifiable, Equatable, Sendable {
    let udid: String
    var id: String { udid }
}

struct IOSDeviceInfo: Equatable, Sendable {
    /// devicectl's spelling of the UDID, which its commands expect.
    var udid: String
    var name: String?
    var model: String?
    var productType: String?
    var osVersion: String?
    var build: String?
    var isPad = false
    var paired = false
    var developerMode: Bool?
    var storage: Int64?
    /// CoreDevice reached the device and listed what it supports; screen recording, for one, depends on the iOS version.
    var connected = false
    /// Reached, but Xcode is still preparing it for development, after an iOS update for one: version and capabilities are stale until then.
    var preparing = false
    var capabilities: Set<String> = []

    /// Screenshots and controls go through developer services: a trusted device with Developer Mode on.
    var isControllable: Bool { paired && developerMode != false && connected }

    func supports(_ feature: String) -> Bool { capabilities.contains(feature) }

    /// DeviceHub shares the screen, with touch and keyboard, from iOS 27 on.
    var canShareScreen: Bool { (osVersion?.split(separator: ".").first.flatMap { Int($0) } ?? 0) >= 27 }

    static let screenshot = "capturescreenshot"
    static let orientation = "remote.devicecontrol.orientation"
    static let screenRecording = "screenrecording"
    static let appearance = "customizeappearancesettings"
    static let voiceOver = "voiceover"
    static let pasteboard = "pasteboard"
}

struct IOSUISettings: Equatable, Sendable {
    var dark: Bool?
    var textSize: String?
    var increaseContrast: Bool?
    var reduceMotion: Bool?
    var voiceOver: Bool?

    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large"]
}

/// Holds one connection to usbmuxd, which pushes each plug and unplug: nothing is polled.
final class UsbmuxTracker: @unchecked Sendable {
    static let socketPath = "/var/run/usbmuxd"
    private let lock = NSLock()
    private var socket: Int32 = -1

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: socketPath) }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket >= 0
    }

    /// `onChange` gets the plugged devices, whether this is the list of devices already there when listening began,
    /// and the UDID of a device that has just been trusted, if any.
    func start(
        onChange: @escaping @Sendable (_ devices: [IOSDevice], _ initial: Bool, _ trusted: String?) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) -> Bool {
        guard !isRunning, let fd = Self.connect() else { return false }
        lock.lock(); socket = fd; lock.unlock()
        let thread = Thread { [weak self] in
            Self.listen(fd, onChange: onChange)
            self?.close(fd)
            onEnd()
        }
        thread.qualityOfService = .utility
        thread.start()
        return true
    }

    func stop() {
        lock.lock(); let fd = socket; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func close(_ fd: Int32) {
        lock.lock()
        if socket == fd { socket = -1 }
        lock.unlock()
        Darwin.close(fd)
    }

    private static func connect() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in socketPath.utf8.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// usbmuxd's protocol: a 16-byte little-endian header (length, version 1, type 8 = plist, tag), then an XML plist.
    private static func listen(_ fd: Int32, onChange: ([IOSDevice], Bool, String?) -> Void) {
        let request: [String: Any] = ["MessageType": "Listen", "ClientVersionString": "Light-mulator", "ProgName": "Light-mulator"]
        guard let body = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) else { return }
        var message = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { message.append(contentsOf: $0) } }
        message.append(body)
        guard message.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == message.count else { return }

        var plugged: [Int: String] = [:]
        var listening: Date?
        while let header = read(fd, count: 16) {
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard length >= 16, let payload = length == 16 ? [] : read(fd, count: length - 16),
                  let plist = try? PropertyListSerialization.propertyList(from: Data(payload), format: nil) as? [String: Any]
            else { return }
            var trusted: String?
            switch plist["MessageType"] as? String {
            case "Result":
                guard (plist["Number"] as? Int) == 0 else { return }
                listening = Date()
                continue
            case "Attached":
                let properties = plist["Properties"] as? [String: Any] ?? [:]
                // Wi-Fi sync attaches and detaches as the phone sleeps: only a cable counts as plugged in.
                guard let id = plist["DeviceID"] as? Int, properties["ConnectionType"] as? String == "USB",
                      let udid = properties["SerialNumber"] as? String else { continue }
                plugged[id] = udid
            case "Detached":
                guard let id = plist["DeviceID"] as? Int, plugged.removeValue(forKey: id) != nil else { continue }
            case "Paired":
                guard let id = plist["DeviceID"] as? Int, let udid = plugged[id] else { continue }
                trusted = udid
            default:
                continue
            }
            // usbmuxd first lists what is already plugged in, right after accepting the request.
            let initial = Date().timeIntervalSince(listening ?? .distantPast) < 1
            let devices = Array(Set(plugged.values)).sorted().map(IOSDevice.init)
            onChange(devices, initial, trusted)
        }
    }

    private static func read(_ fd: Int32, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + filled, count - filled) }
            if got <= 0 { return nil }
            filled += got
        }
        return buffer
    }
}

/// Xcode's CoreDevice tool.
enum DeviceCtl {
    static let path = Xcrun.find("devicectl")

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 30) async -> (status: Int32, output: String) {
        guard let path else { return (-1, "Xcode’s devicectl was not found.") }
        return await Shell.run(path, arguments, timeout: timeout)
    }

    /// The `result` object of the command's JSON report.
    static func result(_ arguments: [String], timeout: TimeInterval = 30) async -> [String: Any]? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard await run(arguments + ["--quiet", "--json-output", file.path], timeout: timeout).status == 0,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["result"] as? [String: Any]
    }

    /// `info details` connects to the device and lists its capabilities; an untrusted device only answers `list`.
    static func info(for udid: String) async -> IOSDeviceInfo? {
        if let device = await result(["device", "info", "details", "--device", udid]), var info = parse(device) {
            let services = (device["deviceProperties"] as? [String: Any])?["ddiServicesAvailable"] as? Bool
            info.connected = services != false
            info.preparing = services == false
            return info
        }
        let key = normalized(udid)
        let devices = await result(["list", "devices"])?["devices"] as? [[String: Any]] ?? []
        return devices.lazy.compactMap(parse).first { normalized($0.udid) == key }
    }

    private static func parse(_ device: [String: Any]) -> IOSDeviceInfo? {
        let properties = device["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? device["hardwareProperties"] as? [String: Any] ?? [:]
        guard let udid = hardware["udid"] as? String else { return nil }
        let legacy = device["deviceProperties"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let software = properties["software"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? device["connectionProperties"] as? [String: Any] ?? [:]
        var info = IOSDeviceInfo(udid: udid)
        info.name = state["name"] as? String ?? legacy["name"] as? String
        info.model = hardware["marketingName"] as? String
        info.productType = hardware["productType"] as? String
        info.isPad = hardware["deviceType"] as? String == "iPad"
        info.storage = (hardware["internalStorageCapacity"] as? NSNumber)?.int64Value
        info.paired = connection["pairingState"] as? String == "paired"
        info.osVersion = legacy["osVersionNumber"] as? String ?? version(software["osVersionNumber"])
        info.build = ((software["osBuildVersions"] as? [String: Any])?["buildVersion"] as? [String: Any])?["name"] as? String
            ?? legacy["osBuildUpdate"] as? String
        if let mode = legacy["developerModeStatus"] as? String {
            info.developerMode = mode == "enabled"
        } else if let mode = state["developerModeStatus"] as? [String: Any] {
            info.developerMode = mode["enabled"] != nil
        }
        let features = (device["capabilities"] as? [[String: Any]] ?? []).compactMap { $0["featureIdentifier"] as? String }
        info.capabilities = Set(features.map { $0.replacingOccurrences(of: "com.apple.coredevice.feature.", with: "") })
        return info
    }

    /// `{"components": [26, 6, 1, 0, 0]}` → "26.6.1".
    private static func version(_ value: Any?) -> String? {
        guard var parts = (value as? [String: Any])?["components"] as? [Int], !parts.isEmpty else { return nil }
        while parts.count > 2, parts.last == 0 { parts.removeLast() }
        return parts.map(String.init).joined(separator: ".")
    }

    static func normalized(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

/// The controls devicectl offers on a real iPhone or iPad.
struct IOSDeviceControl: Sendable {
    let udid: String

    func screenshot(to url: URL) async -> Bool {
        let result = await DeviceCtl.run(["device", "capture", "screenshot", "--device", udid, "--destination", url.path], timeout: 30)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return result.status == 0 && size > 0
    }

    func rotate(clockwise: Bool) async {
        await DeviceCtl.run(["device", "orientation", "rotate", "--device", udid, clockwise ? "right" : "left"])
    }

    func recordingProcess(to url: URL) -> Process? {
        guard let path = DeviceCtl.path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["device", "capture", "screen-record", "--device", udid, "--destination", url.path, "--quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func readUISettings() async -> IOSUISettings {
        async let appearance = DeviceCtl.result(["device", "info", "appearance", "--device", udid])
        async let voiceOver = DeviceCtl.result(["device", "info", "voiceover", "--device", udid])
        let values = await appearance ?? [:]
        return IOSUISettings(
            dark: (values["userInterfaceStyle"] as? String).map { $0.lowercased() == "dark" },
            // Reported as Settings writes it ("Extra Large"), set as devicectl spells it ("extra-large").
            textSize: (values["textSize"] as? String).map { $0.lowercased().replacingOccurrences(of: " ", with: "-") },
            increaseContrast: Self.enabled(values["increaseContrast"]),
            reduceMotion: Self.enabled(values["reduceMotion"]),
            voiceOver: Self.enabled((await voiceOver)?["enabled"])
        )
    }

    func setAppearance(_ option: String, _ value: String) async {
        await DeviceCtl.run(["device", "settings", "appearance", "--device", udid, option, value])
    }

    func setVoiceOver(_ on: Bool) async {
        await DeviceCtl.run(["device", "settings", "voiceover", "--device", udid, on ? "--enable" : "--disable"])
    }

    /// Either a plain flag or `{"enabled": 0}`.
    private static func enabled(_ value: Any?) -> Bool? {
        if let nested = value as? [String: Any] { return enabled(nested["enabled"]) }
        return (value as? NSNumber)?.boolValue
    }
}
