import SwiftUI
import NowCore

struct NotificationSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var notifications: ReminderNotificationController
    @State private var showHelp = false

    private func feature(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in
            store.settings[keyPath: key] = value
            if value { notifications.requestPermission() }
        })
    }

    /// macOS never re-prompts after a denial: flipped-on features could never
    /// deliver, so the toggles are inert until access is restored in Settings.
    private var denied: Bool { notifications.permission.authorization == .denied }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Notify about new updates", isOn: feature(\.notifyUpdates))
                .disabled(!store.settings.automaticUpdateChecks || denied)
            Toggle("Notify about calendar sync problems", isOn: feature(\.notifySyncErrors))
                .disabled(denied)
            if store.settings.usesNotifications {
                Toggle("Hide meeting details in notifications", isOn: $store.settings.hideNotificationDetails)
                    .disabled(denied)
            }
            if denied || (store.settings.usesNotifications && notifications.permission.authorization == .notRequested) {
                Text(notifications.permission.message)
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if notifications.permission.authorization == .notRequested {
                    Button("Enable Notifications…") { notifications.requestPermission() }
                        .disabled(notifications.requesting)
                }
                Button("Notification Settings…") { notifications.openSettings() }
                Button { showHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Notification not received?")
                .help("Notification not received?")
                .popover(isPresented: $showHelp, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notification not received?").font(.headline)
                        Text("In System Settings → Notifications → now, allow notifications and select an onscreen style. Persistent alerts (called Alerts on older macOS versions) stay visible until you act; temporary banners disappear automatically.\n\nCheck notification sound settings, and System Settings → Focus to allow now in the Focus you use. macOS can also hide notifications while the screen is locked, mirrored, or shared.\n\nPermission allows now to submit notifications; it cannot guarantee that macOS displays a banner. Test notifications never change real reminders.")
                            .font(.callout)
                    }
                    .padding(14)
                    .frame(width: 340, alignment: .leading)
                }
                if notifications.requesting { ProgressView().controlSize(.small) }
            }
            if let problem = notifications.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { notifications.refreshPermission(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refreshPermission(force: true)
        }

    }
}

struct NotificationPreviewButton: View {
    @ObservedObject var store: AppStore
    @ObservedObject var notifications: ReminderNotificationController

    var body: some View {
        Button { notifications.previewMeeting(settings: store.settings) } label: {
            Label("Preview Notification Reminder", systemImage: "bell")
        }
        .disabled(!notifications.permission.canSubmit)
        .help(notifications.permission.canSubmit ? "Preview a sample meeting using your notification privacy setting" : "Enable notifications above to preview a meeting reminder")
    }
}
