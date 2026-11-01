import Foundation

/// Downloads model files with byte-level progress.
///
/// Streams chunks to a durable partial file and resumes with HTTP Range after relaunch.
nonisolated final class LocalModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let receivedBytes: Int64
        let totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
    }

    enum DownloadError: LocalizedError {
        case http(Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .http(401): "This model is private or gated. Sign in to Hugging Face with an account that can access it."
            case .http(403): "Your Hugging Face account can't download this model. Gated models need access requested on their Hugging Face page first."
            case .http(let status): "The download failed with HTTP \(status)."
            case .cancelled: "The download was cancelled."
            }
        }
    }

    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        super.init()
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var onTransferProgress: (@Sendable (Int64, Int64, Int64) -> Void)?
    private var transferred: Int64 = 0
    private var task: URLSessionDataTask?
    private var destination: URL?
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var transferError: Error?
    private var partial: URL?
    private var lastProgressReport = Date.distantPast

    /// Minimum gap between progress callbacks. URLSession reports every few
    /// kilobytes, which makes the UI text churn; the final byte always reports.
    static let progressInterval: TimeInterval = 0.5

    /// Downloads `url` to `destination`, replacing anything there. A
    /// `bearerToken` is sent to the Hub only, never to the CDN it redirects to.
    func download(
        _ url: URL,
        to destination: URL,
        bearerToken: String? = nil,
        onTransferProgress: (@Sendable (Int64, Int64, Int64) -> Void)? = nil,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.onProgress = onProgress
                    self.onTransferProgress = onTransferProgress
                    self.destination = destination
                    // One session per download: a downloader instance serves
                    // a single file, and the session retains its delegate
                    // until invalidated below.
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: url)
                    if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
                    let partial = destination.appendingPathExtension("partial")
                    self.partial = partial
                    self.received = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                    if self.received > 0,
                       let validator = try? String(contentsOf: partial.appendingPathExtension("validator"), encoding: .utf8), !validator.isEmpty {
                        request.setValue("bytes=\(self.received)-", forHTTPHeaderField: "Range")
                        request.setValue(validator, forHTTPHeaderField: "If-Range")
                    } else { self.received = 0 }
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                    if Task.isCancelled { task.cancel() }
                }
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(HuggingFaceRedirectGuard.strippingCrossHostAuthorization(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let partial else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                // A complete partial file or a changed remote size can produce 416.
                // Discard it so the next retry makes a fresh request.
                if http.statusCode == 416 { try? FileManager.default.removeItem(at: partial) }
                throw DownloadError.http(http.statusCode)
            }
            if let validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified") {
                try validator.write(to: partial.appendingPathExtension("validator"), atomically: true, encoding: .utf8)
            }
            if http.statusCode == 206 {
                guard http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(received)-") == true else {
                    throw URLError(.badServerResponse)
                }
            } else {
                received = 0
                try Data().write(to: partial)
            }
            if !FileManager.default.fileExists(atPath: partial.path) { try Data().write(to: partial) }
            fileHandle = try FileHandle(forWritingTo: partial)
            try fileHandle?.seekToEnd()
            expected = response.expectedContentLength > 0 ? received + response.expectedContentLength : 0
            // Report the accepted resume offset separately from new network bytes.
            onTransferProgress?(received, expected, 0)
            completionHandler(.allow)
        } catch {
            transferError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            received += Int64(data.count)
            transferred += Int64(data.count)
            let now = Date()
            if received == expected || now.timeIntervalSince(lastProgressReport) >= Self.progressInterval {
                lastProgressReport = now
                onProgress?(received, expected)
                onTransferProgress?(received, expected, transferred)
            }
        } catch {
            transferError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        do {
            try fileHandle?.close()
            fileHandle = nil
            if let error = transferError ?? error { throw error }
            guard let partial, let destination else { throw URLError(.unknown) }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partial, to: destination)
            try? FileManager.default.removeItem(at: partial.appendingPathExtension("validator"))
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
    }
}
