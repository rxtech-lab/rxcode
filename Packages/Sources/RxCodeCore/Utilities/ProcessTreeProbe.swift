import Foundation

#if os(macOS)
import Darwin

// MARK: - Process Tree Open-File Probe

/// Lightweight, non-blocking user-space probe that inspects live child processes
/// of active agent streams using Darwin's `libproc` (`proc_listallpids`,
/// `proc_pidinfo`, `proc_pidfdinfo`) when multiple mutating shell spans overlap
/// in the same workspace.
public enum ProcessTreeProbe {

    /// Samples all descendant processes of each `(streamId: rootPid)` pair and
    /// returns a map of `canonicalFilePath -> Set<streamId>` for any regular file
    /// currently held open with write permissions (`FWRITE`).
    public static func sampleWritableOpenFiles(
        rootPidsByStream: [UUID: Int32],
        canonicalRootPrefix: String
    ) -> [String: Set<UUID>] {
        let validRoots = rootPidsByStream.filter { $0.value > 1 }
        guard !validRoots.isEmpty else { return [:] }

        let childrenMap = buildProcessChildrenMap()
        guard !childrenMap.isEmpty else { return [:] }

        let rootWithSlash = canonicalRootPrefix.hasSuffix("/")
            ? canonicalRootPrefix
            : canonicalRootPrefix + "/"

        var writersByPath: [String: Set<UUID>] = [:]

        for (streamId, rootPid) in validRoots {
            let treePids = collectTreePids(rootPid: rootPid, childrenMap: childrenMap)
            for pid in treePids {
                for path in writableFilePaths(forPid: pid) {
                    if path == canonicalRootPrefix || path.hasPrefix(rootWithSlash) {
                        writersByPath[path, default: []].insert(streamId)
                    }
                }
            }
        }
        return writersByPath
    }

    // MARK: - Private Darwin libproc Helpers

    private static func buildProcessChildrenMap() -> [Int32: [Int32]] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [:] }

        let capacity = Int(estimatedCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesWritten = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(capacity * MemoryLayout<pid_t>.stride))
        }
        guard bytesWritten > 0 else { return [:] }
        let count = min(capacity, Int(bytesWritten) / MemoryLayout<pid_t>.stride)

        var children: [Int32: [Int32]] = [:]
        children.reserveCapacity(count / 2)
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)

        for idx in 0..<count {
            let pid = pids[idx]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bsdSize)
            if got == bsdSize {
                let ppid = Int32(bitPattern: info.pbi_ppid)
                children[ppid, default: []].append(pid)
            }
        }
        return children
    }

    private static func collectTreePids(rootPid: Int32, childrenMap: [Int32: [Int32]]) -> [Int32] {
        var result: [Int32] = [rootPid]
        var visited: Set<Int32> = [rootPid]
        var queueIndex = 0

        while queueIndex < result.count {
            let current = result[queueIndex]
            queueIndex += 1
            guard let kids = childrenMap[current] else { continue }
            for kid in kids where visited.insert(kid).inserted {
                result.append(kid)
            }
        }
        return result
    }

    private static func writableFilePaths(forPid pid: Int32) -> [String] {
        let fdStride = Int32(MemoryLayout<proc_fdinfo>.stride)
        let bufferBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferBytes > 0 else { return [] }

        let fdCount = Int(bufferBytes / fdStride) + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actualBytes = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, base, Int32(fdCount) * fdStride)
        }
        guard actualBytes > 0 else { return [] }

        let actualCount = min(fdCount, Int(actualBytes / fdStride))
        let vnodeStride = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        var paths: [String] = []

        for idx in 0..<actualCount {
            let fdEntry = fds[idx]
            guard fdEntry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }

            var vnodeInfo = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(
                pid,
                fdEntry.proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &vnodeInfo,
                vnodeStride
            )
            guard got == vnodeStride else { continue }

            // In XNU's `proc_fileinfo`, `fi_openflags` stores kernel `FFLAGS`
            // where `FWRITE` (0x0002) is set for O_WRONLY and O_RDWR descriptors.
            guard (vnodeInfo.pfi.fi_openflags & UInt32(FWRITE)) != 0 else { continue }

            let rawPath = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                    String(cString: cStr)
                }
            }
            guard !rawPath.isEmpty else { continue }
            let canonical = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
            paths.append(canonical)
        }

        return paths
    }
}
#endif
