import Foundation

/// One streamed archive. Delegate callbacks write chunks on URLSession's serial
/// queue; cancellation/continuation installation can arrive on other threads.
/// The lock owns both the file handle and the single terminal result.
final class UpdateArchiveDownload: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maxBytes: Int64
    private var count: Int64 = 0
    private var result: Result<Int64, Error>?
    private var continuation: CheckedContinuation<Int64, Error>?

    init(destination: URL, maxBytes: Int64) throws {
        self.maxBytes = maxBytes
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StageFailure(reason: "cannot create staged archive")
        }
        handle = try FileHandle(forWritingTo: destination)
    }

    func install(_ continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func accept(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            finish(StageFailure(reason: "download returned a non-HTTP response")); return false
        }
        guard (200...299).contains(http.statusCode) else {
            finish(StageFailure(reason: "download returned \(http.statusCode)")); return false
        }
        guard response.expectedContentLength <= maxBytes else {
            finish(StageFailure(reason: "update archive larger than \(maxBytes / 1_000_000) MB")); return false
        }
        return true
    }

    func receive(_ data: Data) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        guard Int64(data.count) <= maxBytes - count else {
            lock.unlock()
            finish(StageFailure(reason: "update archive larger than \(maxBytes / 1_000_000) MB"))
            return false
        }
        do {
            try handle.write(contentsOf: data)
            count += Int64(data.count)
            lock.unlock()
            return true
        } catch {
            lock.unlock(); finish(error); return false
        }
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        var outcome: Result<Int64, Error>
        do {
            if let error { throw error }
            try handle.synchronize()
            try handle.close()
            outcome = .success(count)
        } catch {
            try? handle.close()
            outcome = .failure(error)
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}
