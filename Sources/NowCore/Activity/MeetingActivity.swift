package enum MeetingProvider: Equatable, Sendable {
    case zoom, teams, browser, webex, slack, faceTime

    package var name: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .browser: return "Browser"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .faceTime: return "FaceTime"
        }
    }
}

package enum MeetingActivity: Equatable, Sendable {
    case inactive
    case meeting(MeetingProvider)
    case unknown

    package var isDetectedMeeting: Bool { if case .meeting = self { return true }; return false }
}

/// Detection is immediate, inactivity needs two snapshots, unknown fails open.
package struct MeetingActivityDebouncer: Sendable {
    package private(set) var activity: MeetingActivity = .unknown
    private var inactiveSnapshots = 0
    package init() {}

    package mutating func apply(_ detected: MeetingActivity) -> MeetingActivity {
        switch detected {
        case .meeting:
            inactiveSnapshots = 0
            activity = detected
        case .inactive:
            inactiveSnapshots += 1
            if inactiveSnapshots >= 2 { activity = .inactive }
        case .unknown:
            inactiveSnapshots = 0
            activity = .unknown
        }
        return activity
    }

    package mutating func reset() {
        activity = .unknown
        inactiveSnapshots = 0
    }
}
