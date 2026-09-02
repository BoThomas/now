import CoreAudio
import Foundation

enum MeetingProvider: Equatable {
    case zoom
    case teams
    case browser
    case webex
    case slack
    case faceTime

    var name: String {
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

enum MeetingActivity: Equatable {
    case inactive
    case meeting(MeetingProvider)
    case unknown
}

struct MeetingAudioOwner: Equatable {
    let pid: pid_t
    let bundleID: String
}

enum MeetingActivityProbeError: Error, Equatable {
    case processListUnavailable
    case processListUnreadable(OSStatus)
    case inputStateUnavailable

    var message: String {
        switch self {
        case .processListUnavailable:
            return "Meeting detection requires a newer version of macOS."
        case .processListUnreadable, .inputStateUnavailable:
            return "now couldn't read local meeting activity. Reminders will continue normally."
        }
    }
}

enum MeetingActivityProbe {
    nonisolated static var platformPotentiallySupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Read-only CoreAudio metadata snapshot. This never opens an audio device
    /// or captures audio, so it does not require microphone permission.
    nonisolated static func snapshot() -> Result<[MeetingAudioOwner], MeetingActivityProbeError> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(system, &address) else {
            return .failure(.processListUnavailable)
        }
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return .failure(.processListUnreadable(sizeStatus))
        }

        var objectIDs = [AudioObjectID](
            repeating: 0,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.stride)
        let readStatus = objectIDs.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, raw.baseAddress!)
        }
        guard readStatus == noErr else {
            return .failure(.processListUnreadable(readStatus))
        }

        var readableInputStates = 0
        var owners: [MeetingAudioOwner] = []
        for objectID in objectIDs {
            guard let input: UInt32 = scalar(objectID, kAudioProcessPropertyIsRunningInput) else {
                continue
            }
            readableInputStates += 1
            guard input != 0 else { continue }
            let pid: pid_t = scalar(objectID, kAudioProcessPropertyPID) ?? -1
            let bundleID = string(objectID, kAudioProcessPropertyBundleID) ?? ""
            owners.append(MeetingAudioOwner(pid: pid, bundleID: bundleID))
        }
        guard readableInputStates > 0 else { return .failure(.inputStateUnavailable) }
        return .success(owners)
    }

    nonisolated static func activity(owners: [MeetingAudioOwner], includeBrowsers: Bool) -> MeetingActivity {
        let bundleIDs = owners.map { $0.bundleID.lowercased() }
        let matchers: [(MeetingProvider, [String])] = [
            (.zoom, ["us.zoom.xos"]),
            (.teams, ["com.microsoft.teams", "com.microsoft.teams2"]),
            (.webex, ["com.cisco.webex", "cisco-systems.spark"]),
            (.slack, ["com.tinyspeck.slackmacgap"]),
            (.faceTime, ["com.apple.facetime", "com.apple.facetime.ftconversationservice"])
        ]
        for (provider, prefixes) in matchers {
            if bundleIDs.contains(where: { bundleID in prefixes.contains(where: bundleID.hasPrefix) }) {
                return .meeting(provider)
            }
        }

        if includeBrowsers {
            let browserPrefixes = [
                "com.google.chrome",
                "com.apple.safari",
                "com.apple.webkit",
                "org.mozilla.firefox",
                "company.thebrowser.browser",
                "company.thebrowser.dia",
                "com.brave.browser",
                "com.microsoft.edgemac",
                "com.operasoftware.opera",
                "com.opera.neon",
                "net.imput.helium",
                "ai.perplexity.comet",
                "com.openai.atlas",
                "com.browseros.browseros",
                "org.ladybird.ladybird",
                "org.chromium.chromium",
                "com.vivaldi.vivaldi",
                "com.kagi.kagimacos",
                "app.zen-browser",
                "com.sigmaos.sigmaos.macos",
                "com.duckduckgo.macos.browser",
                "io.gitlab.librewolf-community",
                "net.librewolf.librewolf"
            ]
            if bundleIDs.contains(where: { bundleID in browserPrefixes.contains(where: bundleID.hasPrefix) }) {
                return .meeting(.browser)
            }
        }
        if bundleIDs.contains("") { return .unknown }
        return .inactive
    }

    private nonisolated static func scalar<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer) == noErr else {
            return nil
        }
        return pointer.pointee
    }

    private nonisolated static func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

struct MeetingActivityDebouncer {
    private(set) var activity: MeetingActivity = .unknown
    private var inactiveSnapshots = 0

    mutating func apply(_ detected: MeetingActivity) -> MeetingActivity {
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

    mutating func reset() {
        activity = .unknown
        inactiveSnapshots = 0
    }
}

@MainActor
final class MeetingActivitySource {
    var onActivityChange: ((MeetingActivity) -> Void)?
    var onProbeFailure: ((String) -> Void)?

    private var timer: Timer?
    private var generation = 0
    private var probeInFlight = false
    private var includeBrowsers = false
    private var debouncer = MeetingActivityDebouncer()
    private var lastOwners: [MeetingAudioOwner] = []

    deinit {
        timer?.invalidate()
    }

    func checkCapability(_ completion: @escaping (Result<[MeetingAudioOwner], MeetingActivityProbeError>) -> Void) {
        Task {
            let result = await Task.detached(priority: .utility) {
                MeetingActivityProbe.snapshot()
            }.value
            completion(result)
        }
    }

    func start(includeBrowsers: Bool, initialOwners: [MeetingAudioOwner]) {
        stop()
        self.includeBrowsers = includeBrowsers
        lastOwners = initialOwners
        apply(owners: initialOwners)
        timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        probeInFlight = false
        lastOwners = []
        debouncer.reset()
        onActivityChange?(.unknown)
    }

    func setIncludeBrowsers(_ includeBrowsers: Bool) {
        self.includeBrowsers = includeBrowsers
        debouncer.reset()
        let detected = MeetingActivityProbe.activity(owners: lastOwners, includeBrowsers: includeBrowsers)
        let first = debouncer.apply(detected)
        if detected == .inactive {
            onActivityChange?(debouncer.apply(.inactive))
        } else {
            onActivityChange?(first)
        }
    }

    func refreshAfterWake() {
        guard timer != nil else { return }
        debouncer.reset()
        onActivityChange?(.unknown)
        probe()
    }

    private func probe() {
        guard !probeInFlight else { return }
        probeInFlight = true
        let requestGeneration = generation
        Task {
            let result = await Task.detached(priority: .utility) {
                MeetingActivityProbe.snapshot()
            }.value
            guard requestGeneration == generation else { return }
            probeInFlight = false
            switch result {
            case .success(let owners):
                lastOwners = owners
                apply(owners: owners)
            case .failure(let error):
                debouncer.reset()
                onActivityChange?(.unknown)
                onProbeFailure?(error.message)
            }
        }
    }

    private func apply(owners: [MeetingAudioOwner]) {
        let detected = MeetingActivityProbe.activity(owners: owners, includeBrowsers: includeBrowsers)
        onActivityChange?(debouncer.apply(detected))
    }
}
