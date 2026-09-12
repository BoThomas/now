import Foundation

struct CalendarTransportResult {
    var data: Data? = nil
    var error: String? = nil
    var isOffline = false

    static func isOffline(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return false }
        // DNS, timeouts, HTTP failures and refused connections do not prove offline.
        return error.code == NSURLErrorNotConnectedToInternet
    }
}
