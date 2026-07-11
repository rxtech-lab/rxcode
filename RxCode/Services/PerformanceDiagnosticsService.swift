import Darwin
import Foundation
import RxCodeCore
import os

nonisolated struct PerformanceStateSnapshot: Codable, Sendable {
    let workspaceCount: Int
    let projectCount: Int
    let sessionSummaryCount: Int
    let inMemorySessionCount: Int
    let inMemoryMessageCount: Int
    let inMemoryBlockCount: Int
    let largestSessionMessageCount: Int
    let activeStreamCount: Int
    let streamTaskCount: Int
    let flushTaskCount: Int
    let editingFileSnapshotCount: Int
    let sessionRedirectCount: Int
    let pendingCompletionCount: Int
    let completionWaiterCount: Int
    let pendingMobileRequestCount: Int
    let reconciledSessionCount: Int
    let searchIndexedThreadCount: Int
    let searchChunkCount: Int
}

private nonisolated struct ProcessPerformanceMetrics: Codable, Sendable {
    let residentMemoryMB: Double
    let cpuUserSeconds: Double
    let cpuSystemSeconds: Double

    static func current() -> ProcessPerformanceMetrics {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return ProcessPerformanceMetrics(
                residentMemoryMB: 0,
                cpuUserSeconds: 0,
                cpuSystemSeconds: 0
            )
        }
        return ProcessPerformanceMetrics(
            residentMemoryMB: Double(info.resident_size) / 1_048_576,
            cpuUserSeconds: Self.seconds(info.user_time),
            cpuSystemSeconds: Self.seconds(info.system_time)
        )
    }

    private static func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }
}

private nonisolated struct PerformanceLogRecord: Codable, Sendable {
    let timestamp: Date
    let uptimeSeconds: TimeInterval
    let mainActorMaxLagMilliseconds: Double
    let process: ProcessPerformanceMetrics
    let state: PerformanceStateSnapshot
    let events: PerformanceDiagnostics.Snapshot
}

/// Writes a compact JSONL sample every 30 seconds. Records contain only counts,
/// timings, and process metrics; no prompts, paths, session ids, or tool data.
actor PerformanceDiagnosticsService {
    static let shared = PerformanceDiagnosticsService()

    static let logURL = AppSupport.bundleScopedURL
        .appendingPathComponent("diagnostics", isDirectory: true)
        .appendingPathComponent("performance.jsonl")

    private static let maximumLogBytes: UInt64 = 5 * 1_024 * 1_024
    private let logger = Logger(subsystem: "com.claudework", category: "PerformanceDiagnostics")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func append(state: PerformanceStateSnapshot, mainActorMaxLagMilliseconds: Double) {
        let record = PerformanceLogRecord(
            timestamp: .now,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            mainActorMaxLagMilliseconds: mainActorMaxLagMilliseconds,
            process: .current(),
            state: state,
            events: PerformanceDiagnostics.drain()
        )

        do {
            try prepareLogFile()
            var data = try encoder.encode(record)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: Self.logURL.path) {
                FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: Self.logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logger.error("Failed to write performance diagnostics: \(error.localizedDescription)")
        }
    }

    private func prepareLogFile() throws {
        let fileManager = FileManager.default
        let directory = Self.logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let attributes = try? fileManager.attributesOfItem(atPath: Self.logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= Self.maximumLogBytes else { return }

        let rotatedURL = Self.logURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotatedURL)
        try fileManager.moveItem(at: Self.logURL, to: rotatedURL)
    }
}
