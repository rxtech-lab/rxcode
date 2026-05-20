import Darwin
import Foundation
import RxCodeSync

/// Samples the host machine's CPU, memory, and thermal load so the desktop can
/// mirror a "Computer Status" panel to paired mobile devices.
///
/// CPU utilization is a delta between two tick samples; the service keeps the
/// previous sample plus a short result cache so a burst of snapshot broadcasts
/// (one per paired device) share a single, meaningful reading instead of each
/// computing a near-zero delta over a sub-millisecond window.
actor SystemMetricsService {

    static let shared = SystemMetricsService()

    /// Aggregate CPU tick counters read from `host_statistics`.
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
        var total: UInt64 { user &+ system &+ idle &+ nice }
        var busy: UInt64 { user &+ system &+ nice }
    }

    private var previousTicks: CPUTicks?
    private var cached: HostMetricsSnapshot?
    private var cachedAt: Date?
    /// Reuse a reading for this long — longer than a multi-device broadcast
    /// burst, shorter than the mobile pull-to-refresh interval.
    private let cacheTTL: TimeInterval = 2

    /// Current host metrics, served from a short-lived cache when fresh.
    func sample() async -> HostMetricsSnapshot {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        let snapshot = await computeSnapshot()
        cached = snapshot
        cachedAt = Date()
        return snapshot
    }

    private func computeSnapshot() async -> HostMetricsSnapshot {
        let cpu = await currentCPUUsage()
        let memory = currentMemory()
        return HostMetricsSnapshot(
            cpuUsagePercent: cpu,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            thermalState: Self.thermalState(),
            sampledAt: Date()
        )
    }

    // MARK: - CPU

    private func currentCPUUsage() async -> Double {
        guard let current = Self.readCPUTicks() else { return 0 }
        guard let previous = previousTicks else {
            // Cold start: no baseline yet. Take a second sample after a brief
            // pause so the first reading isn't a meaningless 0%.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let second = Self.readCPUTicks() else {
                previousTicks = current
                return 0
            }
            previousTicks = second
            return Self.percentage(from: current, to: second)
        }
        previousTicks = current
        return Self.percentage(from: previous, to: current)
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is indexed by CPU_STATE_{USER,SYSTEM,IDLE,NICE} = 0,1,2,3.
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func percentage(from start: CPUTicks, to end: CPUTicks) -> Double {
        let totalDelta = Double(end.total &- start.total)
        guard totalDelta > 0 else { return 0 }
        let busyDelta = Double(end.busy &- start.busy)
        return min(100, max(0, busyDelta / totalDelta * 100))
    }

    // MARK: - Memory

    private func currentMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return (0, total)
        }
        // Activity Monitor's "Memory Used" footprint: resident pages that
        // aren't trivially reclaimable — active, wired, and compressed.
        let usedPages = UInt64(stats.active_count)
            &+ UInt64(stats.wire_count)
            &+ UInt64(stats.compressor_page_count)
        return (usedPages &* UInt64(pageSize), total)
    }

    // MARK: - Thermal

    private static func thermalState() -> HostMetricsSnapshot.ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}
