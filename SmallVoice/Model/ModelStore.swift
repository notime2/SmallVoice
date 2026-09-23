import CryptoKit
import Foundation
import Observation
import ParakeetKit

/// Downloads, verifies and loads the speech model, and reports where that stands.
@MainActor
@Observable
final class ModelStore {
    enum Status: Equatable {
        case checking
        case downloading(Double)
        case verifying
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .checking
    let engine = ParakeetEngine()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    var isReady: Bool { status == .ready }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Starts (or retries) getting the model ready. Safe to call repeatedly.
    func prepare() {
        guard task == nil, !isReady else { return }
        task = Task {
            await run()
            task = nil
        }
    }

    /// Suspends until the model is ready or has failed; returns whether it is ready.
    func waitUntilReady() async -> Bool {
        if isReady { return true }
        if isFailed { prepare() }
        await withCheckedContinuation { waiters.append($0) }
        return isReady
    }

    private func run() async {
        do {
            if !ModelFiles.isComplete() { try await download() }
            status = .loading
            let started = ContinuousClock.now
            try await engine.load()
            Log.model.info("Model ready in \(ContinuousClock.now - started)")
            status = .ready
        } catch {
            Log.model.error("Model unavailable: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func download() async throws {
        let directory = ModelFiles.defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(ModelFiles.totalSize)
        var completed: Int64 = 0
        status = .downloading(0)

        for file in ModelFiles.files {
            let destination = directory.appending(path: file.name)
            if Self.size(of: destination) == file.size {
                completed += file.size
                continue
            }
            let base = completed
            let temporary = try await FileDownloader.download(ModelFiles.remoteURL(for: file)) { [weak self] written in
                Task { @MainActor in self?.status = .downloading(min(1, Double(base + written) / total)) }
            }
            guard Self.size(of: temporary) == file.size else { throw DownloadError.incomplete(file.name) }
            if let expected = file.sha256 {
                status = .verifying
                let actual = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: temporary) }.value
                guard actual == expected else { throw DownloadError.corrupted(file.name) }
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += file.size
            status = .downloading(Double(completed) / total)
        }
    }

    nonisolated private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? Int64
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum DownloadError: LocalizedError {
    case incomplete(String)
    case corrupted(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .incomplete(let name): String(localized: "The download of \(name) was incomplete")
        case .corrupted(let name): String(localized: "\(name) failed its integrity check")
        case .http(let code): String(localized: "The model server answered with HTTP \(code)")
        }
    }
}

/// One URLSession download with throttled progress, as an async call.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReport = ContinuousClock.now

    private init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    static func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let downloader = FileDownloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.lock.withLock { downloader.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let now = ContinuousClock.now
        let due = lock.withLock {
            guard now - lastReport > .milliseconds(100) else { return false }
            lastReport = now
            return true
        }
        if due { progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted as soon as this returns, so the file has to move now.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            finish(.failure(DownloadError.http(code)))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "SmallVoice-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
