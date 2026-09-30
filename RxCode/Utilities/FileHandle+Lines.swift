import Foundation

extension FileHandle {
    /// Stream newline-delimited lines using a Dispatch-backed `readabilityHandler`.
    ///
    /// Use this instead of `FileHandle.AsyncBytes.lines` for pipes to long-lived
    /// child processes. `AsyncBytes` funnels every iterator through one shared
    /// serial IO queue that performs a blocking `read()`: while one reader waits
    /// on an idle pipe, every other `bytes` reader in the app starves, so a new
    /// agent's replies sit in its pipe and never wake the `for await`. A
    /// readability handler gets its own per-handle dispatch source instead.
    func lineStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            // `buffer` is touched only from the readabilityHandler, which Dispatch
            // serializes onto a single internal queue per FileHandle — no lock needed.
            nonisolated(unsafe) var buffer = Data()
            readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    // EOF — flush any trailing non-terminated line, then finish.
                    if !buffer.isEmpty, let trailing = String(data: buffer, encoding: .utf8) {
                        continuation.yield(trailing)
                        buffer.removeAll(keepingCapacity: false)
                    }
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newlineIdx]
                    buffer.removeSubrange(buffer.startIndex...newlineIdx)
                    if let line = String(data: lineData, encoding: .utf8) {
                        continuation.yield(line)
                    }
                }
            }
            continuation.onTermination = { _ in
                self.readabilityHandler = nil
            }
        }
    }
}
