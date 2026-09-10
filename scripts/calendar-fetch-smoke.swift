import Foundation
import Darwin

private actor Deliveries {
    var values: [(String, TimeInterval)] = []
    private let started = Date()

    func receive(_ result: FetchResult) {
        values.append((result.subscription.name, Date().timeIntervalSince(started)))
    }
}

@main
struct CalendarFetchSmoke {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
        print("PASS: \(message)")
    }

    static func updaterDownloads(base: String) async {
        setenv("NOW_UPDATE_API_BASE", base, 1)
        defer { unsetenv("NOW_UPDATE_API_BASE") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("now-archive-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cap: Int64 = 5_000_000
        for path in ["exact", "over", "stream", "gzip", "error"] {
            let destination = directory.appendingPathComponent(path)
            do {
                let size = try await UpdateStaging.download(request: URLRequest(url: URL(string: base + "/" + path)!), to: destination, maxBytes: cap)
                require(path == "exact" && size == cap, "updater exact byte boundary accepted")
            } catch let error as StageFailure {
                require(path != "exact" && error.reason.contains(path == "error" ? "503" : "5 MB"), "updater \(path) rejected with expected error")
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                require(size <= Int(cap), "updater \(path) never writes beyond cap")
            } catch { require(false, "unexpected updater error: \(error)") }
        }
        for delay in [UInt64(0), 100_000_000] {
            let task = Task {
                try await UpdateStaging.download(request: URLRequest(url: URL(string: base + "/trickle")!), to: directory.appendingPathComponent("cancel"), maxBytes: cap)
            }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            let began = Date(); task.cancel()
            do { _ = try await task.value; require(false, "cancelled archive succeeded") }
            catch { require(Date().timeIntervalSince(began) < 2, "updater cancellation completes promptly") }
        }
        let recovered = try? await UpdateStaging.download(request: URLRequest(url: URL(string: base + "/exact")!), to: directory.appendingPathComponent("recovered"), maxBytes: cap)
        require(recovered == cap, "updater shared session remains usable after failures and cancellation")
    }

    static func structureTests(base: String) async {
        var sub = CalendarSubscription(name: "HTTP structure", url: base + "/populated", colorIndex: 0)
        let populated = await AppStore.performFetch(requests: [FetchRequest(subscription: sub, requestID: 1)])
        require(populated.count == 1 && populated[0].error == nil && populated[0].events.count == 1, "HTTP complete calendar produces a meeting")
        let cached = populated[0].events
        for path in ["incomplete", "incomplete-after-event", "mismatched"] {
            sub.url = base + "/" + path
            let results = await AppStore.performFetch(requests: [FetchRequest(subscription: sub, requestID: 2)])
            let merged = AppStore.mergeICS(current: cached, results: results, live: [sub], previousErrors: [:], latestRequestIDs: [sub.id: 2])
            require(results.count == 1 && results[0].error != nil && results[0].events.isEmpty,
                    "HTTP 200 \(path) is a feed failure, not an empty success")
            require(merged.events.map(\.id) == cached.map(\.id) && merged.errors[sub.id] != nil && !merged.allSucceeded,
                    "\(path) preserves cached meetings and cannot advance last synced")
        }
        sub.url = base + "/fast"
        let empty = await AppStore.performFetch(requests: [FetchRequest(subscription: sub, requestID: 3)])
        let cleared = AppStore.mergeICS(current: cached, results: empty, live: [sub], previousErrors: [sub.id: "old failure"], latestRequestIDs: [sub.id: 3])
        require(cleared.events.isEmpty && cleared.errors.isEmpty && cleared.allSucceeded, "HTTP well-formed empty calendar clears meetings and old errors")
    }

    static func main() async {
        setbuf(stdout, nil)
        let base = CommandLine.arguments[1]
        await structureTests(base: base)
        if CommandLine.arguments.contains("--structure-only") {
            print("CALENDAR STRUCTURE SMOKE OK")
            return
        }
        let cap = AppStore.maxFeedBytes
        let exact = await AppStore.fetchData(base + "/exact")
        require(exact.1 == nil && exact.0?.count == cap, "exactly 5 MB accepted")
        for path in ["over", "stream", "gzip"] {
            let result = await AppStore.fetchData(base + "/" + path)
            require(result.0 == nil && result.1?.contains("5 MB") == true,
                    "\(path): oversized body rejected without returning partial data")
        }
        let started = Date()
        let declared = await AppStore.fetchData(base + "/declared-large")
        require(declared.0 == nil && declared.1?.contains("5 MB") == true && Date().timeIntervalSince(started) < 2,
                "oversized Content-Length rejected after the initial chunk, without waiting for the rest")
        let failed = await AppStore.fetchData(base + "/error")
        require(failed.0 == nil && failed.1 == "Server returned 503", "HTTP errors remain failures")

        let recorder = Deliveries()
        let requests = ["slow", "fast"].map {
            FetchRequest(subscription: CalendarSubscription(name: $0, url: base + "/" + $0, colorIndex: 0), requestID: 42)
        }
        let results = await AppStore.performFetch(requests: requests) { await recorder.receive($0) }
        let deliveries = await recorder.values
        require(results.count == 2 && results.allSatisfy { $0.error == nil && $0.requestID == 42 }, "all batch results retain generations")
        require(deliveries.count == 2 && deliveries[0].0 == "fast" && deliveries[0].1 < 2 && deliveries[1].1 >= 2.5,
                "healthy result delivered while slow feed is still pending")

        // Independent full/targeted operations share the same global slots.
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for batch in 0..<2 {
                group.addTask {
                    let requests = (0..<6).map {
                        FetchRequest(subscription: CalendarSubscription(name: "\(batch)-\($0)", url: base + "/hold", colorIndex: 0), requestID: batch)
                    }
                    let results = await AppStore.performFetch(requests: requests)
                    return results.count == 6 && results.allSatisfy { $0.error == nil }
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    let result = await AppStore.fetchData(base + "/hold")
                    return result.0 != nil && result.1 == nil
                }
            }
            var succeeded = true
            for await result in group { succeeded = succeeded && result }
            return succeeded
        }
        require(succeeded, "overlapping full and targeted downloads all complete")
        let statsData = await AppStore.fetchData(base + "/stats")
        let stats = try! JSONSerialization.jsonObject(with: statsData.0!) as! [String: Any]
        require(stats["peak"] as? Int == AppStore.maxConcurrentFeeds, "server observed at most four simultaneous downloads")
        require(stats["stream_stopped"] as? Bool == true && (stats["stream_bytes"] as? Int ?? Int.max) < cap * 20,
                "oversized stream was cancelled at the server")

        let cancellationStart = Date()
        let cancelled = Task { await AppStore.fetchData(base + "/trickle") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        cancelled.cancel()
        let cancellation = await cancelled.value
        require(cancellation.0 == nil && cancellation.1 != nil && Date().timeIntervalSince(cancellationStart) < 2,
                "cancelling an active download completes promptly")
        for _ in 0..<10 {
            let early = Task { await AppStore.fetchData(base + "/fast") }
            early.cancel()
            _ = await early.value
        }
        let afterCancellation = await AppStore.fetchData(base + "/fast")
        require(afterCancellation.0 != nil && afterCancellation.1 == nil, "early cancellation leaves download slots usable")

        require(AppStore.session.configuration.timeoutIntervalForResource == 60, "production total resource deadline is 60 seconds")
        print("Testing trickle response against the real 60-second deadline…")
        let trickleStart = Date()
        let trickle = await AppStore.fetchData(base + "/trickle")
        let elapsed = Date().timeIntervalSince(trickleStart)
        require(trickle.0 == nil && trickle.1 != nil && elapsed >= 55 && elapsed < 75,
                "continuous incoming data cannot extend total deadline (\(Int(elapsed))s)")
        // Cancellation must free a slot and leave the shared session usable.
        let recovery = await AppStore.fetchData(base + "/fast")
        require(recovery.0 != nil && recovery.1 == nil, "healthy fetch succeeds after timeout")
        await updaterDownloads(base: base)
        print("CALENDAR FETCH SMOKE OK")
    }
}
