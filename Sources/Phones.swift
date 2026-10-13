import Darwin
import Foundation

/// A real device adb sees, over USB or Wi-Fi.
struct ConnectedDevice: Identifiable, Equatable, Sendable {
    let serial: String
    /// adb's word for it: device, unauthorized, offline, authorizing, recovery…
    let state: String
    let model: String?
    let usb: Bool

    var id: String { serial }
    var isReady: Bool { state == "device" }

    /// One line of `adb devices -l`: `<serial> <state> [usb:…] product:… model:Pixel_6_Pro device:… transport_id:…`.
    init?(line: Substring) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        var values: [Substring: Substring] = [:]
        for field in fields.dropFirst(2) {
            guard let colon = field.firstIndex(of: ":") else { continue }
            values[field[..<colon]] = field[field.index(after: colon)...]
        }
        serial = String(fields[0])
        state = fields[1] == "no" ? "no permissions" : String(fields[1])
        model = values["model"].map { $0.replacingOccurrences(of: "_", with: " ") }
        usb = values["usb"] != nil
        // Emulators are listed with their AVD; one reached over TCP still reports an sdk_ product.
        if serial.hasPrefix("emulator-") || values["product"]?.hasPrefix("sdk_") == true { return nil }
    }
}

struct PhoneInfo: Equatable, Sendable {
    /// What the device calls itself in Settings › About, e.g. "Galaxy Tab A11+"; the model code otherwise.
    var name: String?
    var model: String?
    var manufacturer: String?
    var androidVersion: String?
    var apiLevel: Int?
    var screen: Size?
    var density: Int?
    var ram: UInt64?
    var storageTotal: Int64?
    var storageFree: Int64?
    var battery: Battery?

    struct Battery: Equatable, Sendable {
        let level: Int
        let charging: Bool
        let celsius: Double?
    }

    struct Size: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    var isTablet: Bool {
        guard let screen, let density, density > 0 else { return false }
        return min(screen.width, screen.height) * 160 / density >= 600
    }
}

extension DeviceShell {
    var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// Everything the inspector shows, in one round trip.
    func readInfo() async -> PhoneInfo {
        let output = await shell("""
            echo "label=$(settings get global device_name)"; echo "market=$(getprop ro.product.marketname)"; \
            echo "model=$(getprop ro.product.model)"; \
            echo "maker=$(getprop ro.product.manufacturer)"; echo "release=$(getprop ro.build.version.release)"; \
            echo "sdk=$(getprop ro.build.version.sdk)"; wm size; wm density; head -1 /proc/meminfo; \
            echo "data=$(df -k /data | tail -1)"; dumpsys battery
            """, timeout: 15)
        var info = PhoneInfo()
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces) }
        }
        func value(_ key: String) -> String? { values[key].flatMap { $0.isEmpty || $0 == "null" ? nil : $0 } }
        info.model = value("model")
        info.name = value("label") ?? value("market") ?? info.model
        info.manufacturer = values["maker"].flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
        info.androidVersion = values["release"].flatMap { $0.isEmpty ? nil : $0 }
        info.apiLevel = values["sdk"].flatMap { Int($0) }
        let size = (values["Override size"] ?? values["Physical size"] ?? "").split(separator: "x").compactMap { Int($0) }
        if size.count == 2 { info.screen = PhoneInfo.Size(width: size[0], height: size[1]) }
        info.density = (values["Override density"] ?? values["Physical density"]).flatMap { Int($0) }
        info.ram = values["MemTotal"].flatMap { UInt64($0.split(separator: " ").first ?? "") }.map { $0 * 1024 }
        let disk = (values["data"] ?? "").split(separator: " ")
        if disk.count >= 4, let total = Int64(disk[1]), let free = Int64(disk[3]) {
            info.storageTotal = total * 1024
            info.storageFree = free * 1024
        }
        info.battery = Self.battery(values)
        return info
    }

    func readBattery() async -> PhoneInfo.Battery? {
        var values: [String: String] = [:]
        for line in await shell("dumpsys battery").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return Self.battery(values)
    }

    /// `status` 2 is charging, 5 is full and still plugged in.
    private static func battery(_ values: [String: String]) -> PhoneInfo.Battery? {
        guard let level = values["level"].flatMap({ Int($0) }) else { return nil }
        let status = values["status"].flatMap { Int($0) }
        return PhoneInfo.Battery(
            level: level,
            charging: status == 2 || status == 5,
            celsius: values["temperature"].flatMap { Double($0) }.map { $0 / 10 }
        )
    }
}

/// Holds one connection to the adb server, which pushes the device list each time it changes: nothing is polled.
final class AdbTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32 = -1

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket >= 0
    }

    /// False when no adb server is listening.
    func start(onChange: @escaping @Sendable ([ConnectedDevice]) -> Void, onEnd: @escaping @Sendable () -> Void) -> Bool {
        guard !isRunning, let fd = Self.connect() else { return false }
        lock.lock(); socket = fd; lock.unlock()
        let thread = Thread { [weak self] in
            Self.track(fd, onChange: onChange)
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
        let port = ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"].flatMap { UInt16($0) } ?? 5037
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// adb's host protocol: a 4-hex-digit length, then the payload, both ways.
    private static func track(_ fd: Int32, onChange: ([ConnectedDevice]) -> Void) {
        let request = Array("host:track-devices-l".utf8)
        let message = Array(String(format: "%04x", request.count).utf8) + request
        guard message.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == message.count,
              read(fd, count: 4).map({ String(decoding: $0, as: UTF8.self) }) == "OKAY" else { return }
        while let header = read(fd, count: 4), let length = Int(String(decoding: header, as: UTF8.self), radix: 16) {
            guard let payload = length == 0 ? [] : read(fd, count: length) else { return }
            onChange(String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap(ConnectedDevice.init))
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

/// scrcpy, when installed: the live, clickable mirror Android Studio shows for a physical device.
enum Mirror {
    static let path = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
