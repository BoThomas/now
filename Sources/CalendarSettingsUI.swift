import SwiftUI
import NowCore
import AppKit

struct SubscriptionRow: View {
    @Binding var subscription: CalendarSubscription
    let events: [MeetingEvent]
    let error: String?
    let warning: String?
    let cacheStatus: String?
    let existingURLs: [String]
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void
    let onSaveRules: ([TitleFilterRule]) -> Void
    let onDelete: () -> Void
    let onEdited: () -> Void
    @State private var expanded = false
    @State private var showEditSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line when it fits; below ~560 pt the action buttons wrap to a
            // second row instead of crushing the title/URL block.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leadingControls
                    titleBlock
                    expandSpace
                    rowButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        leadingControls
                        titleBlock
                        expandSpace
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        rowButtons
                    }
                }
            }
            if expanded && subscription.isEnabled {
                UpcomingEventList(
                    events: events,
                    error: error,
                    colorHex: subscription.colorHex,
                    rules: subscription.titleFilters,
                    onMute: onMute,
                    onRemoveRules: onRemoveRules
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: subscription.isEnabled) { enabled in
            if !enabled { expanded = false }
        }
        .sheet(isPresented: $showEditSheet) {
            EditCalendarView(subscription: $subscription, existingURLs: existingURLs) {
                onEdited()
            }
        }
    }

    private var leadingControls: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $subscription.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(subscription.isEnabled ? "Disable calendar (stops sync and reminders)" : "Enable calendar")
                .accessibilityLabel("\(subscription.isEnabled ? "Disable" : "Enable") calendar \(subscription.name)")
            ColorPicker("", selection: Binding(
                get: { Palette.color(hex: subscription.colorHex) },
                set: { subscription.colorHex = Palette.hexString(from: NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(x: 0.75, y: 0.75)
            .frame(width: 24, height: 20)
            .padding(.leading, 2)
            .accessibilityLabel("Event color for \(subscription.name)")
        }
    }

    /// Clickable dead space between the title block and the action buttons —
    /// the same expand/collapse as the chevron, deliberately WITHOUT any visual
    /// affordance of its own (no hover highlight, cursor stays default).
    private var expandSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard subscription.isEnabled else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subscription.name).font(.system(size: 13, weight: .semibold))
            Text(Self.displayURL(subscription.url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help("Full URL is visible in the edit sheet")
            if let cacheStatus {
                Text(cacheStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let warning = warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .opacity(subscription.isEnabled ? 1 : 0.5)
    }

    private var rowButtons: some View {
        HStack(spacing: 12) {
            filterButton
            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit name or URL")
            .accessibilityLabel("Edit calendar \(subscription.name)")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove calendar")
            .accessibilityLabel("Remove calendar \(subscription.name)")
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(-6)
            .disabled(!subscription.isEnabled)
            .help(subscription.isEnabled ? "Show upcoming events" : "Calendar disabled")
            .accessibilityLabel(expanded ? "Hide events for \(subscription.name)" : "Show events for \(subscription.name)")
        }
    }

    /// Muted-meetings rule editor entry. The live count is an overlay badge (not
    /// flow text) so the icon's layout box stays identical to the neighboring
    /// edit/trash icons — mixed image+text labels sit visibly higher otherwise.
    private var filterButton: some View {
        CalendarFilterButton(calendarName: subscription.name, rules: subscription.titleFilters,
                             events: events, available: true, onSaveRules: onSaveRules)
    }

    /// Sanitized feed URL for display outside the editor: shared iCal links
    /// embed secret tokens in path/query, so rows show only the host. The full
    /// URL remains visible (and editable) inside the edit sheet.
    static func displayURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : "\(host)/…"
    }
}

/// One calendar from EventKit: toggle = use it, color = tint for its events
/// (seeded from the calendar's own color on first enable), funnel = muted-meeting
/// rules, chevron = upcoming events.
struct NativeCalendarRow: View {
    let info: NativeCalendarInfo
    let isOn: Bool
    let colorHex: String
    let events: [MeetingEvent]
    /// Rules of the persisted record (empty when the calendar was never enabled —
    /// then there is no record and no rule storage yet).
    let rules: [TitleFilterRule]
    let calendarID: UUID?
    let onToggle: (Bool) -> Void
    let onColor: (String) -> Void
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void
    let onSaveRules: ([TitleFilterRule]) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wrap the chevron to a second row in narrow windows.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leadingControls
                    titleBlock
                    expandSpace
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        leadingControls
                        titleBlock
                        expandSpace
                    }
                    HStack {
                        Spacer()
                        actionButtons
                    }
                }
            }
            if expanded && isOn {
                UpcomingEventList(
                    events: events,
                    error: nil,
                    colorHex: colorHex,
                    rules: rules,
                    onMute: onMute,
                    onRemoveRules: onRemoveRules
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: isOn) { enabled in
            if !enabled { expanded = false }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            filterButton
            expandButton
        }
    }

    /// Muted-meetings rule editor. Needs a persisted record (our stable UUID) —
    /// a never-enabled calendar has none, so the button waits for first enable.
    /// Disabled-but-previously-enabled calendars keep editing their rules.
    /// The count is an overlay badge so the icon aligns with the chevron.
    private var filterButton: some View {
        CalendarFilterButton(calendarName: info.title, rules: rules, events: events,
                             available: calendarID != nil, onSaveRules: onSaveRules)
    }

    /// Clickable dead space between the title block and the action buttons —
    /// the same expand/collapse as the chevron, deliberately WITHOUT any visual
    /// affordance of its own (no hover highlight, cursor stays default).
    private var expandSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isOn else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
    }

    private var leadingControls: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(isOn ? "Stop reminders for this calendar" : "Show reminders for this calendar")
                .accessibilityLabel("\(isOn ? "Stop reminders for" : "Show reminders for") \(info.title)")
            ColorPicker("", selection: Binding(
                get: { Palette.color(hex: colorHex) },
                set: { onColor(Palette.hexString(from: NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(x: 0.75, y: 0.75)
            .frame(width: 24, height: 20)
            .padding(.leading, 2)
            .disabled(!isOn)
            .help(isOn ? "Tint for this calendar's events" : "Enable the calendar to pick a color")
            .accessibilityLabel("Event color for \(info.title)")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title).font(.system(size: 13, weight: .semibold))
            Text(info.sourceTitle.isEmpty ? "Apple Calendars" : "via \(info.sourceTitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .opacity(isOn ? 1 : 0.5)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(-6)
        .disabled(!isOn)
        .help(isOn ? "Show upcoming events" : "Calendar disabled")
        .accessibilityLabel(expanded ? "Hide events for \(info.title)" : "Show events for \(info.title)")
    }
}

/// Shared badge, accessibility and sheet lifecycle for both calendar sources.
private struct CalendarFilterButton: View {
    let calendarName: String
    let rules: [TitleFilterRule]
    let events: [MeetingEvent]
    let available: Bool
    let onSaveRules: ([TitleFilterRule]) -> Void
    @State private var showing = false
    @State private var generation = 0

    var body: some View {
        Button { generation += 1; showing = true } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .overlay(alignment: .bottomTrailing) {
                    if !rules.isEmpty {
                        Text("\(rules.count)")
                            .font(.system(size: 8, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white).padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 5, y: 4).allowsHitTesting(false)
                    }
                }
                .offset(y: 2)
        }
        .buttonStyle(.borderless)
        .disabled(!available)
        .help(!available ? "Enable the calendar first" : (rules.isEmpty ? "Muted meetings — none yet" : "Muted meetings (\(rules.count) rules)"))
        .accessibilityLabel("Muted meetings rules for \(calendarName)")
        .sheet(isPresented: $showing) {
            if available {
                TitleFilterEditorSheet(calendarName: calendarName, rules: rules, events: events, onSave: onSaveRules)
                    .id(generation)
            }
        }
    }
}
