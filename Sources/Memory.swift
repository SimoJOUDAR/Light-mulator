import Darwin
import Foundation

/// The Mac's memory as Activity Monitor shows it, read with plain syscalls.
struct MacMemory: Equatable, Sendable {
    enum Pressure: Int, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    let total: UInt64
    /// App memory + wired + compressed: Activity Monitor's "Memory Used". Cached files don't count.
    let used: UInt64
    let swapUsed: UInt64
    let pressure: Pressure

    var available: UInt64 { total > used ? total - used : 0 }

    /// Below this, a change wouldn't show in a figure rounded to a tenth of a GB.
    static let visibleStep: UInt64 = 64 << 20

    func isClose(to other: MacMemory) -> Bool {
        func near(_ a: UInt64, _ b: UInt64) -> Bool { max(a, b) - min(a, b) < Self.visibleStep }
        return pressure == other.pressure && total == other.total && near(used, other.used) && near(swapUsed, other.swapUsed)
    }

    private static let host = mach_host_self()

    static func read() -> MacMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MacMemory(
            total: ProcessInfo.processInfo.physicalMemory,
            used: used,
            swapUsed: swapUsed,
            pressure: Pressure(rawValue: Int(level)) ?? .normal
        )
    }
}
