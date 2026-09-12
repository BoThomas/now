import Foundation

/// Request generations span full and targeted refreshes for each source.
package struct FetchTracker: Sendable {
    private var nextID = 1
    package private(set) var latestPerSubscription: [UUID: Int] = [:]
    package init() {}

    package mutating func begin(subscriptionID: UUID) -> Int {
        let id = nextID; nextID += 1
        latestPerSubscription[subscriptionID] = id
        return id
    }

    package mutating func beginFull(subscriptionIDs: [UUID]) -> Int {
        let id = nextID; nextID += 1
        for subscriptionID in subscriptionIDs { latestPerSubscription[subscriptionID] = id }
        return id
    }
}

package struct FetchRequest: Sendable {
    package let subscription: CalendarSubscription
    package let requestID: Int
    package init(subscription: CalendarSubscription, requestID: Int) {
        self.subscription = subscription; self.requestID = requestID
    }
}

package struct FetchResult: Sendable {
    package let subscription: CalendarSubscription
    package let events: [MeetingEvent]
    package let error: String?
    package var warning: String?
    package var requestID = 0
    package var fetchedAt: Date?
    package var isOffline = false

    package init(subscription: CalendarSubscription, events: [MeetingEvent], error: String?, warning: String? = nil, requestID: Int = 0, fetchedAt: Date? = nil, isOffline: Bool = false) {
        self.subscription = subscription; self.events = events; self.error = error
        self.warning = warning; self.requestID = requestID; self.fetchedAt = fetchedAt; self.isOffline = isOffline
    }
}
