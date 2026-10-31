import Foundation

/// Downloads model files with byte-level progress.
///
/// A delegate-based `URLSessionDownloadTask` rather than `bytes(from:)`: GGUF
/// files run to tens of gigabytes, and the download task streams straight to
/// disk instead of through the app.
nonisolated final class LocalModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var session: URLSession?

    /// Downloads `url` to `destination`, replacing anything there. A
    /// `bearerToken` is sent to the Hub only, never to the CDN it redirects to.
    func download(
        _ url: URL,
        to destination: URL,
        bearerToken: String? = nil,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.onProgress = onProgress
                    self.destination = destination
                    // One session per download: a downloader instance serves
                    // a single file, and the session retains its delegate
                    // until invalidated below.
                    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: url)
                    if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
                    let task = session.downloadTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(HuggingFaceRedirectGuard.strippingCrossHostAuthorization(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.withLock { onProgress }?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let (continuation, destination) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?) in
            defer { self.continuation = nil }
            return (self.continuation, self.destination)
        }
        guard let continuation, let destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation.resume(throwing: DownloadError.http(http.statusCode))
            return
        }
        do {
            // The temporary file is deleted when this method returns, so it
            // has to be moved now, synchronously.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume(returning: destination)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: DownloadError.cancelled)
        } else {
            continuation?.resume(throwing: error)
        }
    }
}
