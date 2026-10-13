import Foundation

struct Paths {
    let sdk: URL
    let userHome: URL
    let avdHome: URL

    var emulator: URL { sdk.appendingPathComponent("emulator/emulator") }
    var adb: URL { sdk.appendingPathComponent("platform-tools/adb") }
    var hasEmulator: Bool { FileManager.default.isExecutableFile(atPath: emulator.path) }
    var hasAdb: Bool { FileManager.default.isExecutableFile(atPath: adb.path) }

    static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Light-mulator")

    static func resolve() -> Paths {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultSdk = home.appendingPathComponent("Library/Android/sdk")
        let sdkCandidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0) } + [defaultSdk]
        let sdk = sdkCandidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("emulator").path)
        } ?? defaultSdk
        let userHome = env["ANDROID_USER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".android")
        let avdHome = env["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? userHome.appendingPathComponent("avd")
        return Paths(sdk: sdk, userHome: userHome, avdHome: avdHome)
    }
}

enum INI {
    static func parse(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// Rewrites only the given keys, keeping every other line and the original order.
    static func update(_ url: URL, with updates: [String: String]) throws {
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var remaining = updates
        for index in lines.indices {
            guard let eq = lines[index].firstIndex(of: "=") else { continue }
            let key = lines[index][..<eq].trimmingCharacters(in: .whitespaces)
            if let value = remaining.removeValue(forKey: key) {
                lines[index] = "\(key)=\(value)"
            }
        }
        if lines.last == "" { lines.removeLast() }
        lines += remaining.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct AVD: Identifiable, Hashable {
    let id: String
    let dir: URL
    let ini: URL?
    let config: [String: String]
    let problem: String?

    var isUsable: Bool { problem == nil }
    var configURL: URL { dir.appendingPathComponent("config.ini") }

    var displayName: String {
        if let name = config["avd.ini.displayname"], !name.isEmpty { return name }
        return id
    }

    var apiLevel: Int? {
        let source = config["image.sysdir.1"] ?? config["target"] ?? ""
        guard let range = source.range(of: #"android-\d+"#, options: .regularExpression) else { return nil }
        return Int(source[range].dropFirst("android-".count))
    }

    var androidVersion: String? { apiLevel.flatMap(Self.androidVersionName) }

    static func androidVersionName(_ api: Int) -> String? {
        let names: [Int: String] = [
            37: "17", 36: "16", 35: "15", 34: "14", 33: "13", 32: "12L", 31: "12", 30: "11",
            29: "10", 28: "9", 27: "8.1", 26: "8.0", 25: "7.1", 24: "7.0", 23: "6.0",
        ]
        return names[api]
    }

    var variant: String? {
        if let tag = config["tag.display"], !tag.isEmpty { return tag }
        return config["PlayStore.enabled"] == "true" ? "Google Play" : nil
    }

    var abi: String? {
        config["abi.type"].map { $0.replacingOccurrences(of: "-v8a", with: "") }
    }

    var ramMB: Int? { Self.megabytes(config["hw.ramSize"]) }

    var screen: String? {
        guard let w = config["hw.lcd.width"], let h = config["hw.lcd.height"] else { return nil }
        return "\(w)×\(h)"
    }

    var symbol: String {
        let tags = (config["tag.ids"] ?? config["tag.id"] ?? "").lowercased()
        if tags.contains("wear") { return "applewatch" }
        if tags.contains("tv") { return "tv" }
        if tags.contains("automotive") { return "car" }
        if tags.contains("desktop") { return "desktopcomputer" }
        if let w = Double(config["hw.lcd.width"] ?? ""), let h = Double(config["hw.lcd.height"] ?? ""),
           let density = Double(config["hw.lcd.density"] ?? ""), density > 0,
           min(w, h) / (density / 160) >= 600 {
            return "ipad.landscape"
        }
        return "iphone"
    }

    static func megabytes(_ raw: String?) -> Int? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces).uppercased(), !value.isEmpty else { return nil }
        var factor = 1
        if value.hasSuffix("G") { factor = 1024; value.removeLast() } else if value.hasSuffix("M") { value.removeLast() }
        return Int(value).map { $0 * factor }
    }
}

enum AVDRepository {
    static func load(_ paths: Paths) -> [AVD] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: paths.avdHome, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [AVD] = []
        var claimed = Set<String>()

        for ini in items where ini.pathExtension == "ini" {
            let id = ini.deletingPathExtension().lastPathComponent
            let meta = INI.parse(ini) ?? [:]
            var dir = meta["path"].map { URL(fileURLWithPath: $0) }
            if dir.map({ !fm.fileExists(atPath: $0.path) }) ?? true, let rel = meta["path.rel"] {
                dir = paths.userHome.appendingPathComponent(rel)
            }
            let resolved = dir ?? paths.avdHome.appendingPathComponent("\(id).avd")
            claimed.insert(resolved.standardizedFileURL.path)
            let exists = fm.fileExists(atPath: resolved.path)
            result.append(AVD(
                id: id,
                dir: resolved,
                ini: ini,
                config: INI.parse(resolved.appendingPathComponent("config.ini")) ?? [:],
                problem: exists ? nil : "Folder missing — only the .ini is left"
            ))
        }

        for dir in items where dir.pathExtension == "avd" && !claimed.contains(dir.standardizedFileURL.path) {
            result.append(AVD(
                id: dir.deletingPathExtension().lastPathComponent,
                dir: dir,
                ini: nil,
                config: INI.parse(dir.appendingPathComponent("config.ini")) ?? [:],
                problem: "Leftover folder without .ini — invisible to Android Studio"
            ))
        }

        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func delete(_ avd: AVD, paths: Paths) throws {
        let fm = FileManager.default
        if let ini = avd.ini, fm.fileExists(atPath: ini.path) {
            try fm.removeItem(at: ini)
        }
        // A malformed .ini could point anywhere: only ever remove a real "*.avd" folder.
        if avd.dir.pathExtension == "avd", avd.dir.pathComponents.count > 3, fm.fileExists(atPath: avd.dir.path) {
            try fm.removeItem(at: avd.dir)
        }
        // The emulator logs to ~/.android/<id>/emulator.log: drop the log, and the folder only once it's empty,
        // since an AVD id can collide with one of ~/.android's own folders.
        let emulatorLog = paths.userHome.appendingPathComponent(avd.id).appendingPathComponent("emulator.log")
        try? fm.removeItem(at: emulatorLog)
        let logFolder = emulatorLog.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: logFolder.path))?.isEmpty == true {
            try? fm.removeItem(at: logFolder)
        }
        try? fm.removeItem(at: Paths.logs.appendingPathComponent("\(avd.id).log"))
    }

    /// Same files Android Studio drops: the next boot rebuilds them from the system image, like a new AVD.
    static let wipedFiles = [
        "userdata-qemu.img", "userdata-qemu.img.qcow2",
        "cache.img", "cache.img.qcow2",
        "encryptionkey.img", "encryptionkey.img.qcow2",
        "snapshots",
    ]

    static func wipe(_ avd: AVD) throws {
        let fm = FileManager.default
        for name in wipedFiles {
            let url = avd.dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    static func sanitizedID(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func skippedOnDuplicate(_ name: String) -> Bool {
        name.hasSuffix(".lock") || [
            "hardware-qemu.ini", "snapshots", "tmpAdbCmds", "emu-launch-params.txt",
            "read-snapshot.txt", "bootcompleted.ini",
        ].contains(name)
    }

    /// Files are copied with FileManager, which clones them on APFS: the copy costs no disk until it diverges.
    static func duplicate(_ avd: AVD, name: String, paths: Paths) throws -> String {
        let fm = FileManager.default
        let newID = sanitizedID(name)
        guard !newID.isEmpty else { throw AppError("The name needs at least one letter or digit.") }
        let newDir = paths.avdHome.appendingPathComponent("\(newID).avd")
        let newIni = paths.avdHome.appendingPathComponent("\(newID).ini")
        guard !fm.fileExists(atPath: newDir.path), !fm.fileExists(atPath: newIni.path) else {
            throw AppError("An emulator with the ID “\(newID)” already exists.")
        }

        try fm.createDirectory(at: newDir, withIntermediateDirectories: false)
        do {
            for item in try fm.contentsOfDirectory(at: avd.dir, includingPropertiesForKeys: nil)
            where !skippedOnDuplicate(item.lastPathComponent) {
                try fm.copyItem(at: item, to: newDir.appendingPathComponent(item.lastPathComponent))
            }
            try INI.update(newDir.appendingPathComponent("config.ini"), with: [
                "AvdId": newID,
                "avd.ini.displayname": name,
            ])
            var ini = INI.parse(avd.ini ?? newIni) ?? [:]
            ini["path"] = newDir.path
            ini["path.rel"] = paths.avdHome.deletingLastPathComponent().standardizedFileURL == paths.userHome.standardizedFileURL
                ? "avd/\(newID).avd" : nil
            if ini["avd.ini.encoding"] == nil { ini["avd.ini.encoding"] = "UTF-8" }
            let order = ["avd.ini.encoding", "path", "path.rel", "target"]
            let keys = order.filter { ini[$0] != nil } + ini.keys.filter { !order.contains($0) }.sorted()
            try (keys.map { "\($0)=\(ini[$0]!)" }.joined(separator: "\n") + "\n")
                .write(to: newIni, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: newDir)
            try? fm.removeItem(at: newIni)
            throw error
        }
        return newID
    }
}

enum DiskUsage {
    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func totalSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// GB with one decimal, like the rest of the window; smaller sizes as Finder writes them.
    static func format(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? "\(Format.diskNumber(bytes)) GB"
            : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
