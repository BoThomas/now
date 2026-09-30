import Foundation
import NowCore
import SwiftUI

/// Stable feature IDs, not release numbers: an upgrade can cross several introductions.
/// Append entries when adding features; never rename an ID or remove it from history.
struct FeatureGuideDefinition: Identifiable, Equatable {
    enum Content: Equatable {
        case notifications
        case displayChoice
        case joinInApp
        case information(title: String, message: String)
    }
    let id: String
    let content: Content
}

enum FeatureGuideCatalog {
    static let notificationsID = "notification-setup-v1"
    static let displayID = "fullscreen-display-v1"
    static let joinInAppID = "join-links-in-app-v1"
    static let entries = [
        FeatureGuideDefinition(id: notificationsID, content: .notifications),
        // Interactive: the card's Show on choice applies on Continue; closing
        // it keeps the focused default. Deliberately not gated on the current
        // screen count: a user who updates while docked to one display may
        // still use several.
        FeatureGuideDefinition(id: displayID, content: .displayChoice),
        // Interactive: the join-in-app choice applies on Continue. The card
        // starts checked from the setting's on-by-default state; closing the
        // card keeps the current setting, unchecking plus Complete disables
        // the https upgrade. Native-protocol links (zoomus://, msteams:…)
        // are always honored and need no setting.
        FeatureGuideDefinition(id: joinInAppID, content: .joinInApp)
    ]
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

/// A guide commits once, after validation, while its page and settings are still current.
@MainActor
final class NotificationGuideSubmission: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    private var generation = UUID()

    func cancel() { generation = UUID(); problem = nil }

    func apply(_ choices: NotificationSetupChoices, to store: AppStore,
               permission: () async -> Bool,
               probe: () async -> Result<[MeetingAudioOwner], MeetingActivityProbeError>) async -> Bool {
        guard !busy else { return false }
        busy = true
        problem = nil
        let token = generation
        let original = store.settings
        defer { busy = false }
        var owners: [MeetingAudioOwner]?
        // Keep an existing detection session/retry intact when only other choices change.
        if choices.duringMeetings && original.inMeetingDelivery != .notification {
            let result = await probe()
            guard generation == token else { return false }
            switch result {
            case .success(let value): owners = value
            case .failure(let error):
                problem = "Your settings are unchanged. \(error.message) Try again or turn off ‘During another meeting’."
                return false
            }
        }
        // Recheck without prompting, including after a suspended capability check.
        let allowed = choices.needsPermission ? await permission() : true
        guard generation == token else { return false }
        guard store.settings == original else {
            problem = "Settings changed while setup was open. Review your choices and try again."
            return false
        }
        guard allowed else {
            problem = "Your settings are unchanged. Allow notifications or turn off the notification choices."
            return false
        }
        store.applyNotificationSetup(choices, owners: owners)
        return true
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
/// Multiple newly introduced features are paged ONE CARD AT A TIME with dot
/// indicators: a shared scroll area is easy to miss (overlay scrollbars only
/// appear while scrolling), so a second card stacked below the first would
/// effectively be invisible. The footer is pure navigation (Next, and
/// Back + Complete from page two on); card-specific actions like the
/// notifications permission flow live inside their card. Closing the window
/// (traffic light / ⌘W) is the "not now" path and counts the guides as seen.
struct FeatureGuideView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var notifications: ReminderNotificationController
    @ObservedObject var guides: FeatureGuideController
    let ids: [String]
    var onFinish: () -> Void = {}
    var usesKeyboardShortcuts: Bool
    @State private var choices: NotificationSetupChoices
    @State private var displayChoice: ReminderScreen
    @State private var joinInAppChoice: Bool
    @State private var busy = false
    @State private var problem: String?
    @State private var permissionBlocked = false
    @State private var generation = UUID()
    @State private var page = 0
    @StateObject private var submission = NotificationGuideSubmission()

    private var isBusy: Bool { busy || submission.busy }

    init(store: AppStore, notifications: ReminderNotificationController, guides: FeatureGuideController, ids: [String], usesKeyboardShortcuts: Bool = false, onFinish: @escaping () -> Void = {}) {
        self.store = store
        self.notifications = notifications
        self.guides = guides
        self.ids = ids
        self.onFinish = onFinish
        self.usesKeyboardShortcuts = usesKeyboardShortcuts
        _choices = State(initialValue: NotificationSetupChoices(settings: store.settings))
        _displayChoice = State(initialValue: store.settings.reminderScreen)
        _joinInAppChoice = State(initialValue: store.settings.openJoinsInMeetingApp)
    }

    private var cards: [FeatureGuideDefinition] { guides.definitions(for: ids) }
    private var isLastPage: Bool { page >= cards.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if cards.count > 1 {
                HStack(spacing: 6) {
                    ForEach(cards.indices, id: \.self) { index in
                        Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Feature \(page + 1) of \(cards.count)")
            }
            if cards.indices.contains(page) {
                let card = cards[page]
                PopupScrollView {
                    cardContent(card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(card.id)
                HStack {
                    if isBusy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    if page > 0 {
                        Button("Back") { generation = UUID(); page -= 1 }
                            .disabled(isBusy)
                    }
                    Button(isLastPage ? "Complete" : "Next") { advance(from: card) }
                        .keyboardShortcut(usesKeyboardShortcuts ? .defaultAction : nil)
                        .disabled(isBusy)
                }
            }
        }
        .onDisappear { generation = UUID(); submission.cancel() }
    }

    @ViewBuilder
    private func cardContent(_ card: FeatureGuideDefinition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch card.content {
            case .notifications:
                Text("New in this version: Notifications").font(.headline)
                Text("Notifications can remind you about meetings and let you know about calendar sync problems and available updates. Choose which ones you want below.")
                    .font(.callout).foregroundStyle(.secondary)
                if !notifications.permission.canSubmit {
                    // Same gating as Settings: options stay unavailable until
                    // notification access is enabled. The button requests
                    // permission only (no page change, no applying); the
                    // unlocked toggles plus Next/Complete do the rest.
                    Button(permissionBlocked ? "Check Permission & Enable" : "Enable Notifications…") { enableNotifications() }
                        .disabled(isBusy)
                }
                Toggle("During another meeting", isOn: $choices.duringMeetings)
                    .disabled(!notifications.permission.canSubmit || !MeetingActivityProbe.platformPotentiallySupported || isBusy)
                Toggle("Meetings in progress after launch or wake", isOn: $choices.catchUp)
                    .disabled(!notifications.permission.canSubmit || isBusy)
                Toggle("Calendar sync problems", isOn: $choices.syncErrors)
                    .disabled(!notifications.permission.canSubmit || isBusy)
                Toggle("New updates available", isOn: $choices.updates)
                    .disabled(!notifications.permission.canSubmit || isBusy || !store.settings.automaticUpdateChecks)
                if !store.settings.automaticUpdateChecks {
                    Text("Update notifications require automatic update checks, which are currently off.").font(.caption).foregroundStyle(.secondary)
                }
                if !MeetingActivityProbe.platformPotentiallySupported {
                    Text("Meeting detection requires macOS 14 or later.").font(.caption).foregroundStyle(.secondary)
                }
            case .displayChoice:
                Text("New in this version: Pick your reminder display").font(.headline)
                Text("Fullscreen reminders take over the display you are working on. Pick where they should appear. You can change this anytime in Settings → Reminder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Show on")
                    Picker("", selection: $displayChoice) {
                        Text("Focused Display").tag(ReminderScreen.focused)
                        Text("Main Display").tag(ReminderScreen.mainDisplay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Intrinsic width, never a constrained frame — see the
                    // segmented-picker note in SettingsUI.swift.
                    .fixedSize()
                    .accessibilityLabel("Fullscreen reminder display")
                }
            case .joinInApp:
                Text("New in this version: Open meetings directly in the app").font(.headline)
                Text("Join links with a direct app protocol such as zoomus:// now open the meeting app right away without a browser detour. Ordinary Zoom and Teams links can do the same when the app is installed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Open Zoom and Teams links always in the meeting app, if installed", isOn: $joinInAppChoice)
            case .information(let title, let message):
                Text(title).font(.headline)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = problem ?? submission.problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if permissionBlocked {
                Button("Open Notification Settings…") { store.notifications?.openSettings() }
            }
        }
    }

    private func finish() {
        generation = UUID()
        submission.cancel()
        onFinish()
    }

    /// Advances to the next newly introduced feature, or finishes on the last.
    private func advancePage() {
        generation = UUID()
        submission.cancel()
        problem = nil
        permissionBlocked = false
        if page < cards.count - 1 { page += 1 } else { finish() }
    }

    /// Footer navigation: applies the current page's choice where one exists
    /// and moves on. The notifications page applies its toggles once no
    /// permission prompt would be needed (access granted or nothing on); the
    /// in-card button owns the permission request itself.
    private func advance(from card: FeatureGuideDefinition) {
        guard !isBusy else { return }
        switch card.content {
        case .notifications:
            guard notifications.permission.canSubmit || !choices.needsPermission else {
                advancePage()
                return
            }
            problem = nil
            permissionBlocked = false
            let token = generation
            let selected = choices
            Task { @MainActor in
                guard generation == token else { return }
                let applied = await submission.apply(selected, to: store,
                    permission: { await notifications.checkPermission().canSubmit },
                    probe: { await Task.detached(priority: .utility) { MeetingActivityProbe.snapshot() }.value })
                if applied { advancePage() }
            }
        case .displayChoice:
            store.settings.reminderScreen = displayChoice
            advancePage()
        case .joinInApp:
            store.settings.openJoinsInMeetingApp = joinInAppChoice
            advancePage()
        case .information:
            advancePage()
        }
    }

    /// In-card action while notification access is missing: requests
    /// permission only. The page stays put; the grant unlocks the toggles, and
    /// Next/Complete applies the choices (capability checks run through the
    /// standard settings path).
    private func enableNotifications() {
        guard !isBusy else { return }
        let token = generation
        busy = true
        problem = nil
        Task { @MainActor in
            defer { busy = false }
            guard let notifications = store.notifications, await notifications.authorizeForSetup() else {
                guard generation == token else { return }
                permissionBlocked = true
                problem = "Your settings are unchanged. Allow now in System Settings → Notifications, then check permission here to finish setup."
                return
            }
            guard generation == token else { return }
            permissionBlocked = false
        }
    }
}
