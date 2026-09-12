import Foundation
import NowCore
import SwiftUI

/// Stable feature IDs, not release numbers: an upgrade can cross several introductions.
/// Append entries when adding features; never rename an ID or remove it from history.
struct FeatureGuideDefinition: Identifiable, Equatable {
    enum Content: Equatable {
        case notifications
        case information(title: String, message: String)
    }
    let id: String
    let content: Content
}

enum FeatureGuideCatalog {
    static let notificationsID = "notification-setup-v1"
    static let entries = [FeatureGuideDefinition(id: notificationsID, content: .notifications)]
}

struct FeatureGuideState: Codable, Equatable {
    var encountered: Set<String> = []
    var pendingPresentation: Set<String> = []

    private enum CodingKeys: String, CodingKey { case encountered, pendingSettings, pendingPresentation }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        encountered = try values.decodeIfPresent(Set<String>.self, forKey: .encountered) ?? []
        pendingPresentation = try values.decodeIfPresent(Set<String>.self, forKey: .pendingPresentation) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(encountered, forKey: .encountered)
        try values.encode(pendingPresentation, forKey: .pendingPresentation)
        // Older releases require this key to decode the encountered history.
        // Retain an empty wire field for downgrades, without retired UI state.
        try values.encode(Set<String>(), forKey: .pendingSettings)
    }

    /// Called only after startup health is acknowledged. Union retains history
    /// across downgrades too. Closing/skipping a guide does not nag next release.
    mutating func acknowledge(catalog: [FeatureGuideDefinition], installedUpdate: Bool, existingProfile: Bool = false) -> [String] {
        let introduced = catalog.filter { !encountered.contains($0.id) }
        encountered.formUnion(catalog.map(\.id))
        if installedUpdate || existingProfile { pendingPresentation.formUnion(introduced.map(\.id)) }
        return catalog.map(\.id).filter { pendingPresentation.contains($0) }
    }
}

struct NotificationSetupChoices: Equatable {
    var duringMeetings: Bool
    var catchUp: Bool
    var updates: Bool
    var syncErrors: Bool
    var needsPermission: Bool { duringMeetings || catchUp || updates || syncErrors }

    init(settings: AppSettings, supportsMeetings: Bool = MeetingActivityProbe.platformPotentiallySupported) {
        // Existing notification and suppression choices survive. Only unconfigured
        // users receive the new recommendations; update notifications are new.
        duringMeetings = supportsMeetings && (settings.usesNotifications ? settings.notifyDuringMeetings : settings.inMeetingDelivery != .suppress)
        catchUp = settings.usesNotifications ? settings.notifyOnCatchUp : true
        updates = settings.automaticUpdateChecks
        syncErrors = settings.usesNotifications ? settings.notifySyncErrors : true
    }
}

@MainActor
final class FeatureGuideController: ObservableObject {
    static let storageKey = "local.tboch.now.feature-guides.v1"
    @Published private(set) var state: FeatureGuideState
    @Published private(set) var updateIDs: [String] = []
    let catalog: [FeatureGuideDefinition]
    private let defaults: UserDefaults
    private var acknowledged = false

    init(defaults: UserDefaults = AppPreferences.standard, catalog: [FeatureGuideDefinition] = FeatureGuideCatalog.entries) {
        self.defaults = defaults
        self.catalog = catalog
        state = StoredPreferences.load(FeatureGuideState.self, key: Self.storageKey, label: "Feature guide history", defaults: defaults) ?? FeatureGuideState()
    }

    func startupHealthAcknowledged(installedUpdate: Bool, existingProfile: Bool = false) {
        guard !acknowledged else { return }
        acknowledged = true
        updateIDs = state.acknowledge(catalog: catalog, installedUpdate: installedUpdate, existingProfile: existingProfile)
        save()
    }

    /// Called only after the containing window becomes visible. Keep the
    /// in-memory IDs for that window, but never repeat a seen/skipped guide.
    func didPresent() {
        state.pendingPresentation.subtract(updateIDs)
        save()
    }

    func definitions(for ids: [String]) -> [FeatureGuideDefinition] { catalog.filter { ids.contains($0.id) } }
    private func save() {
        StoredPreferences.save(state, key: Self.storageKey, label: "Feature guide history", defaults: defaults)
    }
}

/// Update-success feature guides. Future informational
/// cards require only a catalog entry; interactive features add a content case.
struct FeatureGuideView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var guides: FeatureGuideController
    let ids: [String]
    var onFinish: () -> Void = {}
    var usesKeyboardShortcuts: Bool
    @State private var choices: NotificationSetupChoices
    @State private var busy = false
    @State private var problem: String?
    @State private var permissionBlocked = false
    @State private var generation = UUID()

    init(store: AppStore, guides: FeatureGuideController, ids: [String], usesKeyboardShortcuts: Bool = false, onFinish: @escaping () -> Void = {}) {
        self.store = store
        self.guides = guides
        self.ids = ids
        self.onFinish = onFinish
        self.usesKeyboardShortcuts = usesKeyboardShortcuts
        _choices = State(initialValue: NotificationSetupChoices(settings: store.settings))
    }
    private var hasNotifications: Bool { guides.definitions(for: ids).contains { $0.content == .notifications } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(guides.definitions(for: ids)) { guide in
                switch guide.content {
                case .notifications:
                    Text("New in this version: Notifications").font(.headline)
                    Text("Notifications can remind you about meetings and let you know about calendar sync problems and available updates. Choose which ones you want below.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("During another meeting", isOn: $choices.duringMeetings)
                        .disabled(!MeetingActivityProbe.platformPotentiallySupported || busy)
                    Toggle("Meetings in progress after launch or wake", isOn: $choices.catchUp).disabled(busy)
                    Toggle("Calendar sync problems", isOn: $choices.syncErrors).disabled(busy)
                    Toggle("New updates available", isOn: $choices.updates).disabled(busy || !store.settings.automaticUpdateChecks)
                    if !store.settings.automaticUpdateChecks {
                        Text("Update notifications require automatic update checks, which are currently off.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !MeetingActivityProbe.platformPotentiallySupported {
                        Text("Meeting detection requires macOS 14 or later.").font(.caption).foregroundStyle(.secondary)
                    }
                case .information(let title, let message):
                    Text(title).font(.headline)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if permissionBlocked {
                Button("Open Notification Settings…") { store.notifications?.openSettings() }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button(hasNotifications ? "Maybe Later" : "Close") { finish() }
                    .keyboardShortcut(usesKeyboardShortcuts ? .cancelAction : nil)
                Button(hasNotifications && choices.needsPermission ? (permissionBlocked ? "Check Permission & Enable" : "Enable Notifications…") : "Continue") { enable() }
                    .keyboardShortcut(usesKeyboardShortcuts ? .defaultAction : nil)
                    .disabled(busy)
            }
        }
        .onDisappear { generation = UUID() }
    }
    private func finish() {
        generation = UUID()
        onFinish()
    }
    private func enable() {
        guard !busy else { return }
        guard hasNotifications else { finish(); return }
        let token = generation
        let original = store.settings
        let selected = choices
        busy = true
        problem = nil
        Task { @MainActor in
            defer { busy = false }
            if selected.needsPermission {
                guard let notifications = store.notifications, await notifications.authorizeForSetup() else {
                    guard generation == token else { return }
                    permissionBlocked = true
                    problem = "Your settings are unchanged. Allow now in System Settings → Notifications, then check permission here to finish setup."
                    return
                }
            }
            guard generation == token else { return }
            var owners: [MeetingAudioOwner]?
            if selected.duringMeetings {
                let result = await Task.detached(priority: .utility) { MeetingActivityProbe.snapshot() }.value
                guard generation == token else { return }
                switch result {
                case .success(let snapshot): owners = snapshot
                case .failure(let error):
                    problem = "Your settings are unchanged. \(error.message) You can try again or turn off ‘During another meeting’."
                    return
                }
            }
            guard generation == token, store.settings == original else {
                problem = "Settings changed while setup was open. Review your choices and try again."
                return
            }
            store.applyNotificationSetup(selected, owners: owners)
            finish()
        }
    }
}
