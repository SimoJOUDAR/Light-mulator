import Darwin
import Foundation

enum Shell {
    /// Output goes through a temp file, not a pipe: `adb` may fork its server, which would keep a pipe open forever.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("emu-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: out) }
        let status = await run(executable, arguments, writingTo: out, includeErrors: true, timeout: timeout)
        return (status, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
    }

    /// Writes stdout to `out` as is, for binary output such as a screenshot.
    static func run(
        _ executable: String,
        _ arguments: [String],
        writingTo out: URL,
        includeErrors: Bool = false,
        timeout: TimeInterval
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                FileManager.default.createFile(atPath: out.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: out) else {
                    continuation.resume(returning: -1); return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = handle
                process.standardError = includeErrors ? handle : FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    try? handle.close()
                    continuation.resume(returning: -1); return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                try? handle.close()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}

struct RunningInfo: Equatable, Sendable {
    let pid: pid_t
    let consolePort: Int?
    let memory: UInt64
    let started: Date?
}

/// Finds running emulators with plain syscalls — no `ps`/`adb` spawn on every refresh.
enum ProcessScanner {
    private static let runningDirs: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TemporaryItems/avd/running"),
        FileManager.default.temporaryDirectory.appendingPathComponent("avd/running"),
    ]

    static func scan() -> [String: RunningInfo] {
        var result: [String: RunningInfo] = [:]
        for pid in emulatorPIDs() {
            var id: String?
            var port: Int?
            for dir in runningDirs {
                if let ini = INI.parse(dir.appendingPathComponent("pid_\(pid).ini")), let avd = ini["avd.id"] {
                    id = avd
                    port = ini["port.serial"].flatMap { Int($0) }
                    break
                }
            }
            if id == nil { (id, port) = parse(arguments(of: pid)) }
            guard let id else { continue }
            result[id] = RunningInfo(pid: pid, consolePort: port, memory: footprint(of: pid), started: startTime(of: pid))
        }
        return result
    }

    /// Booted simulators by UDID, with the memory of everything their `launchd_sim` runs.
    static func scanSimulators() -> [String: RunningInfo] {
        let pids = allPIDs()
        let roots = pids.filter { name(of: $0) == "launchd_sim" }
        guard !roots.isEmpty else { return [:] }
        var children: [pid_t: [pid_t]] = [:]
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids where proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            children[pid_t(info.pbi_ppid), default: []].append(pid)
        }
        var result: [String: RunningInfo] = [:]
        for root in roots {
            guard let udid = arguments(of: root).lazy.compactMap(udid(in:)).first else { continue }
            var total: UInt64 = 0
            var stack = [root]
            while let pid = stack.popLast() {
                total += footprint(of: pid)
                stack += children[pid] ?? []
            }
            result[udid] = RunningInfo(pid: root, consolePort: nil, memory: total, started: startTime(of: root))
        }
        return result
    }

    private static func udid(in argument: String) -> String? {
        guard let range = argument.range(of: #"/Devices/[0-9A-F-]{36}/"#, options: .regularExpression) else { return nil }
        return String(argument[range].dropFirst("/Devices/".count).dropLast())
    }

    private static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).filter { $0 > 0 }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func emulatorPIDs() -> [pid_t] {
        allPIDs().filter { name(of: $0).hasPrefix("qemu-system") }
    }

    private static func parse(_ args: [String]) -> (String?, Int?) {
        var id: String?
        var port: Int?
        for (index, arg) in args.enumerated() {
            let next = index + 1 < args.count ? args[index + 1] : nil
            if arg == "-avd" { id = next }
            else if arg.hasPrefix("@") && arg.count > 1 { id = String(arg.dropFirst()) }
            else if arg == "-port" || arg == "-ports" { port = next?.split(separator: ",").first.flatMap { Int($0) } }
        }
        return (id, port)
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// Same number as Activity Monitor's "Memory" column.
    private static func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }
}
