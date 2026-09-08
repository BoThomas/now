import Foundation
import SwiftUI

/// A persisted draft keeps first-run choices separate from active settings.
/// Existing profiles are enrolled as completed, even if they have no sources.
struct SetupAssistantState: Codable, Equatable {
    enum Step: String, Codable, CaseIterable {
        case welcome, reminders, ready
        var title: String {
            switch self {
            case .welcome: return "Be ready for every meeting"
            case .reminders: return "Your meeting reminders"
            case .ready: return "You're set"
            }
        }
    }
    // Migrate drafts from the earlier five-screen prototype without restarting.
    private enum CodingKeys: String, CodingKey { case completed, step, draft }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        completed = try values.decode(Bool.self, forKey: .completed)
        draft = try values.decode(AppSettings.self, forKey: .draft)
        let savedStep = try values.decode(String.self, forKey: .step)
        step = savedStep == "context" ? .reminders : (savedStep == "notifications" ? .welcome : (Step(rawValue: savedStep) ?? .welcome))
    }
    var completed: Bool
    var step: Step = .welcome
    var draft: AppSettings

    init(isNewProfile: Bool, settings: AppSettings, supportsMeetings: Bool) {
        completed = !isNewProfile
        draft = settings
        if isNewProfile {
            draft.leadSeconds = 60
            draft.snoozeSeconds = 0
            draft.inMeetingDelivery = supportsMeetings ? .notification : .normal
            draft.catchUpDelivery = .notification
            draft.notifyUpdates = settings.automaticUpdateChecks
        }
    }

    static func applying(_ draft: AppSettings, to current: AppSettings) -> AppSettings {
        var result = current
        result.leadSeconds = draft.leadSeconds
        result.reminderDelivery = draft.reminderDelivery
        result.inMeetingDelivery = draft.inMeetingDelivery
        result.catchUpDelivery = draft.catchUpDelivery
        result.hideNotificationDetails = draft.hideNotificationDetails
        result.notifyUpdates = draft.notifyUpdates
        result.launchAtLogin = draft.launchAtLogin
        result.automaticUpdateChecks = draft.automaticUpdateChecks
        return result
    }

    mutating func withoutNotifications() {
        draft.reminderDelivery = .fullscreen
        if draft.inMeetingDelivery == .notification { draft.inMeetingDelivery = .normal }
        if draft.catchUpDelivery == .notification { draft.catchUpDelivery = .normal }
        draft.notifyUpdates = false
        draft.notifySyncErrors = false
    }

    static func effective(_ draft: AppSettings, notificationsAllowed: Bool) -> AppSettings {
        guard !notificationsAllowed else { return draft }
        var state = SetupAssistantState(isNewProfile: false, settings: draft, supportsMeetings: false)
        state.withoutNotifications()
        return state.draft
    }

    var steps: [Step] { Step.allCases }
    mutating func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }
    mutating func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }
}

@MainActor
final class SetupAssistantController: ObservableObject {
    nonisolated static let storageKey = "local.tboch.now.initial-setup.v1"
    @Published private(set) var state: SetupAssistantState
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    private let defaults: UserDefaults
    private var generation = 0
    var draft: AppSettings {
        get { state.draft }
        set { generation += 1; state.draft = newValue; problem = nil; save() }
    }
    var pending: Bool { !state.completed }

    init(isNewProfile: Bool, settings: AppSettings, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(SetupAssistantState.self, from: $0) }
            ?? SetupAssistantState(isNewProfile: isNewProfile, settings: settings, supportsMeetings: MeetingActivityProbe.platformPotentiallySupported)
        save()
    }
    func next() { guard !busy else { return }; problem = nil; state.next(); save() }
    func back() { guard !busy else { return }; generation += 1; problem = nil; state.back(); save() }
    func cancelPendingWork() { generation += 1 }

    /// Injectable validation keeps tests off Notification Center/CoreAudio.
    /// Permission gates the effective choices without erasing the draft. Only
    /// exposed preferences and enabled notification defaults are committed.
    func complete(store: AppStore,
                  permission: () async -> Bool,
                  probe: () async -> Result<[MeetingAudioOwner], MeetingActivityProbeError>) async -> Bool {
        guard pending, !busy, state.step == .ready else { return false }
        busy = true
        problem = nil
        let request = generation
        let requested = draft
        defer { busy = false }
        let allowed = await permission()
        let selected = SetupAssistantState.effective(requested, notificationsAllowed: allowed)
        guard request == generation else { return false }
        var owners: [MeetingAudioOwner]?
        if selected.needsMeetingDetection {
            let result = await probe()
            guard request == generation else { return false }
            switch result {
            case .success(let value): owners = value
            case .failure(let error):
                state.step = .reminders
                problem = error.message + " Choose ‘Remind normally’ to continue without meeting detection."
                save()
                return false
            }
        }
        guard request == generation else { return false }
        store.applyInitialSetup(selected, owners: owners)
        state.completed = true
        save()
        return true
    }
    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct SetupAssistantView: View {
    @ObservedObject var assistant: SetupAssistantController
    @ObservedObject var store: AppStore
    @ObservedObject var alerts: AlertController
    @ObservedObject var notifications: ReminderNotificationController
    let onFinish: () -> Void
    @State private var customLead = false
    @State private var showNotificationHelp = false

    private var effective: AppSettings {
        SetupAssistantState.applying(SetupAssistantState.effective(assistant.draft, notificationsAllowed: notifications.permission.canSubmit), to: store.settings)
    }
    private func choice<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { assistant.draft[keyPath: key] }, set: { assistant.draft[keyPath: key] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("now").font(.system(size: 20, weight: .bold))
                Spacer()
                Text("Step \((assistant.state.steps.firstIndex(of: assistant.state.step) ?? 0) + 1) of 3")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if assistant.state.step != .ready {
                Text(assistant.state.step.title).font(.system(size: 24, weight: .semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem = assistant.problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if assistant.state.step != .welcome {
                    Button("Back") { assistant.back() }.disabled(assistant.busy || notifications.requesting)
                }
                Spacer()
                if assistant.busy { ProgressView().controlSize(.small) }
                Button(assistant.state.step == .ready ? "Add Meeting Sources…" : "Continue") {
                    if assistant.state.step == .ready { finish() }
                    else { assistant.next() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(assistant.busy || customLead || notifications.requesting)
            }
        }
        .padding(28)
        .frame(width: 560, height: 430)
        .background(VisualEffectBackground())
        .onAppear { notifications.refreshPermission(force: true) }
        .onDisappear { assistant.cancelPendingWork() }
    }

    @ViewBuilder private var content: some View {
        switch assistant.state.step {
        case .welcome:
            Text("Glad you're here. Let's get you set up.").foregroundStyle(.secondary)
            Toggle("Start now at login", isOn: choice(\.launchAtLogin))
            Toggle("Check for updates automatically", isOn: choice(\.automaticUpdateChecks))
            HStack {
                if notifications.permission.canSubmit {
                    Label("Notifications enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if notifications.permission.authorization == .denied {
                    Button("Enable Notifications in System Settings…") { notifications.openSettings() }
                } else {
                    Button("Enable Notifications…") { notifications.requestPermission() }.disabled(notifications.requesting)
                }
                if notifications.requesting { ProgressView().controlSize(.small) }
                Button { showNotificationHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About notification access")
                    .popover(isPresented: $showNotificationHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notification access").font(.headline)
                            Text("Notification options stay unavailable until access is enabled. You can come back here later. In System Settings → Notifications → now, choose your alert style, sound, and Focus behavior.")
                            Button("Open Notification Settings…") { notifications.openSettings() }
                            Button("Check Permission Again") { notifications.refreshPermission(force: true) }
                        }.padding(16).frame(width: 330)
                    }
            }
            if let problem = notifications.problem { Text(problem).foregroundStyle(.orange).font(.callout) }
        case .reminders:
            HStack {
                Picker("Reminder style", selection: Binding(get: { effective.reminderDelivery }, set: { assistant.draft.reminderDelivery = $0 })) {
                    Text("Fullscreen").tag(ReminderDelivery.fullscreen)
                    Text("macOS notification").tag(ReminderDelivery.notification).disabled(!notifications.permission.canSubmit)
                }
                Button {
                    if effective.reminderDelivery == .notification { notifications.previewMeeting(settings: effective) }
                    else { alerts.presentPreview(settings: effective) }
                } label: {
                    Label("Preview", systemImage: effective.reminderDelivery == .notification ? "bell" : "eye")
                }
                .help("Preview the selected reminder style")
            }
            Picker("Remind me", selection: Binding(get: { assistant.draft.leadSeconds }, set: {
                if $0 == -1 { customLead = true } else { assistant.draft.leadSeconds = $0 }
            })) {
                ForEach(Array(Set([0, 10, 30, 60, 120, 300, 600, 900, assistant.draft.leadSeconds])).sorted(), id: \.self) { seconds in
                    Text(seconds == 0 ? "Just in time" : "\(Fmt.leadTime(seconds)) before").tag(seconds)
                }
                Text("Custom…").tag(-1)
            }
            .popover(isPresented: $customLead) {
                CustomTimingEditor(title: "Remind me before start", seconds: assistant.draft.leadSeconds, range: AppSettings.leadSecondsRange,
                                   onApply: { assistant.draft.leadSeconds = $0; customLead = false }, onCancel: { customLead = false })
            }
            Picker("During another meeting", selection: Binding(get: { effective.inMeetingDelivery }, set: { assistant.draft.inMeetingDelivery = $0 })) {
                Text("Remind normally").tag(InMeetingDelivery.normal)
                Text("Use a notification").tag(InMeetingDelivery.notification).disabled(!notifications.permission.canSubmit)
                Text("Suppress reminders").tag(InMeetingDelivery.suppress)
            }.disabled(!MeetingActivityProbe.platformPotentiallySupported)
            Toggle("Hide meeting details in notifications", isOn: choice(\.hideNotificationDetails))
                .disabled(!notifications.permission.canSubmit)
        case .ready:
            VStack(spacing: 18) {
                Text("🎉").font(.system(size: 64))
                Text("You're set!").font(.title2.weight(.semibold))
                Text("Add your meeting sources to get started.").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 32)
        }
    }
    private func finish() {
        Task { @MainActor in
            let finished = await assistant.complete(store: store, permission: {
                await notifications.checkPermission().canSubmit
            }, probe: {
                await Task.detached(priority: .utility) { MeetingActivityProbe.snapshot() }.value
            })
            if finished { onFinish() }
        }
    }
}
