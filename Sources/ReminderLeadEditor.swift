import SwiftUI
import NowCore

/// Empty rows and custom-editor targets are transient UI state, never scheduling identities.
struct ReminderLeadEditor: View {
    /// Matches the three-entry cap in `AppSettings.normalizedLeads`.
    private static let maximumLeads = 3

    @Binding var leads: [Int]
    @State private var adding = false
    @State private var showInformation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(leads, id: \.self) { lead in
                HStack {
                    // The topmost reminder stays: removing rows top-down would
                    // reorder the list the user reads. Borderless stays on each
                    // icon button: on the row it would also strip the popup
                    // button's bevel (an NSPopUpButton is a button).
                    if leads.count > 1, lead != leads.first {
                        Button { leads.removeAll { $0 == lead } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove " + Fmt.reminderTiming(lead) + " reminder")
                    }
                    ReminderLeadPicker(value: lead) { value in
                        guard leads.contains(lead) else { return }
                        leads = AppSettings.normalizedLeads(leads.filter { $0 != lead } + [value])
                    }
                }
            }
            if adding {
                HStack {
                    Button { adding = false } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel adding reminder")
                    ReminderLeadPicker(value: nil) { value in
                        leads = AppSettings.normalizedLeads(leads + [value])
                        adding = false
                    }
                }
            }
            HStack {
                if !adding, leads.count < Self.maximumLeads {
                    Button { adding = true } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add reminder time")
                }
                Button { showInformation.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("How multiple reminders work")
                    .popover(isPresented: $showInformation) { information }
            }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Multiple reminders").font(.headline)
            Text("You get one reminder per configured time. Snoozing pauses all reminders for this meeting; closing one leaves later reminders active.")
            Text("After joining, later reminders stay quiet unless meeting detection is enabled and notices you are not in a meeting.")
            Text("Times you add here only apply going forward.")
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

private struct ReminderLeadPicker: View {
    let value: Int?
    let apply: (Int) -> Void
    @State private var custom = false

    var body: some View {
        Picker("Remind me", selection: Binding(get: { value ?? -2 }, set: {
            if $0 == -1 { custom = true } else if $0 >= 0 { apply($0) }
        })) {
            if value == nil { Text("Choose time…").tag(-2) }
            ForEach(AppSettings.leadDurations(including: value ?? 300), id: \.self) { seconds in
                Text(Fmt.reminderTiming(seconds)).tag(seconds)
            }
            Divider()
            Text("Custom…").tag(-1)
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityLabel("Reminder timing")
        .popover(isPresented: $custom, arrowEdge: .bottom) {
            CustomTimingEditor(title: "Remind me before start", seconds: value ?? 300, range: AppSettings.leadSecondsRange,
                               onApply: { apply($0); custom = false }, onCancel: { custom = false })
        }
    }
}
