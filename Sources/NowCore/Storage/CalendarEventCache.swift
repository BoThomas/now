// The serial POSIX adapter is shared by macOS and Linux. Windows needs its own
// filesystem implementation; snapshot policy is independent of this adapter.
#if os(macOS) || os(Linux)
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// All filesystem work is serialized off the main actor. Calls enqueue immediately,
/// preserving save/remove order even when a source is edited while a write runs.
package final class CalendarEventCache: @unchecked Sendable {
    package static let maxSnapshotBytes = 16 * 1_000_000
    package static let maxTotalBytes = 64 * 1_000_000
    package let directory: URL
    private let queue = DispatchQueue(label: "now.calendar-cache", qos: .utility)

    package init(directory: URL) {
        self.directory = directory
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func recoveryFile(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".recovery.json") }

    private func sourceID(_ url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        let raw = name.hasSuffix(".recovery") ? String(name.dropLast(9)) : name
        guard let id = UUID(uuidString: raw), id.uuidString == raw else { return nil }
        return id
    }

    package func load(subscriptions: [CalendarSubscription], retireInvalidSnapshots: Bool = true) async -> CalendarCacheLoad {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = CalendarCacheLoad()
                var total = 0
                for subscription in subscriptions.filter(\.isEnabled).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    let url = self.file(subscription.id)
                    do {
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true,
                              let size = values.fileSize, size <= Self.maxSnapshotBytes,
                              size <= Self.maxTotalBytes - total else { throw CacheError.invalid }
                        total += size
                        // Bounded read also protects against a file growing after stat.
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: Self.maxSnapshotBytes + 1) ?? Data()
                        guard data.count <= Self.maxSnapshotBytes else { throw CacheError.invalid }
                        let snapshot = try JSONDecoder().decode(CalendarCacheSnapshot.self, from: data)
                        guard snapshot.isValid, snapshot.matches(subscription) else { throw CacheError.invalid }
                        result.snapshots[subscription.id] = snapshot
                    } catch {
                        let failure = error as NSError
                        if (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
                            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)) { continue }
                        result.issues[subscription.id] = "Saved calendar data could not be loaded. Refresh to restore offline availability."
                        // A read/metadata/permission failure doesn't prove corruption.
                        // Leave those files available for a later attempt.
                        if retireInvalidSnapshots && (error is DecodingError || error is CacheError) {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    package func save(_ snapshot: CalendarCacheSnapshot, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            let destination = self.file(snapshot.calendarID)
            let recovery = self.recoveryFile(snapshot.calendarID)
            let temporary = self.directory.appendingPathComponent(".write-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                guard snapshot.isValid,
                      snapshot.meetings.reduce(1024 + (snapshot.warning?.utf8.count ?? 0) * 6, { $0 + $1.estimatedBytes }) <= Self.maxSnapshotBytes
                else { throw CacheError.invalid }
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= Self.maxSnapshotBytes else { throw CacheError.invalid }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
                let otherSize = try self.cacheFiles().filter { self.sourceID($0) != snapshot.calendarID }.reduce(0) {
                    $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                guard data.count <= Self.maxTotalBytes - otherSize else { throw CacheError.invalid }
                // Apply permissions before the atomic replacement. A metadata
                // failure must not discard a successfully replaced live snapshot.
                try data.write(to: temporary, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                guard rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                try? FileManager.default.removeItem(at: recovery)
                completion(nil)
            } catch {
                // A newer accepted feed can remove meetings. Preserve the old
                // bytes for recovery, but never automatically restore that obsolete
                // agenda. One recovery copy per source stays within the disk budget.
                if FileManager.default.fileExists(atPath: destination.path) {
                    if rename(destination.path, recovery.path) != 0 {
                        // If quarantine is impossible, still retire obsolete data.
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                completion("Calendar synced, but its offline copy could not be saved. It may be unavailable after restarting.")
            }
        }
    }

    package func remove(_ ids: Set<UUID>) {
        queue.async {
            for id in ids {
                try? FileManager.default.removeItem(at: self.file(id))
                try? FileManager.default.removeItem(at: self.recoveryFile(id))
            }
        }
    }

    package func retain(_ ids: Set<UUID>) {
        queue.async {
            for url in (try? self.cacheFiles()) ?? [] {
                if let id = self.sourceID(url), !ids.contains(id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Enqueue synchronously: AppKit's termination loop need not service Tasks.
    package func whenIdle(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    /// Await queued disk writes/removals, useful for controlled shutdown tests.
    package func flush() async {
        await withCheckedContinuation { continuation in whenIdle { continuation.resume() } }
    }

    private func cacheFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter {
            $0.pathExtension == "json" && self.sourceID($0) != nil
        }
    }

    private enum CacheError: Error { case invalid }
}

#endif
