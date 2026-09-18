import SwiftUI
import AppKit

/// The update window content — one window class, four states (available /
/// up to date / installed / problem). Plain SwiftUI keyboard shortcuts are
/// safe here: both buttons always exist, so the alert's vanishing-button
/// keyMonitor machinery is deliberately not used. No HTML/JS in release
/// notes, ever.
struct UpdateView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.windowContent {
            case .available(let manifest):
                if controller.isBrewManaged {
                    brewAvailableView(manifest)
                } else {
                    availableView(manifest)
                }
            case .upToDate:
                upToDateView
            case .installed(let version):
                installedView(version)
            case .features(let version):
                installedView(version, confirmedInstall: false)
            case .problem(let title, let message, let retry):
                problemView(title: title, message: message, retry: retry)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground())
        .background(PopupWindowSizing())
    }

    // MARK: - Update available

    private func availableView(_ manifest: UpdateManifest) -> some View {
        let staged = controller.stagedVersion == manifest.version
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("now \(manifest.version)")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Released \(manifest.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())) · currently on \(UpdateLogic.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT'S NEW")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                PopupScrollView {
                    // Consolidated body when the jump skipped intermediate
                    // releases; the offered release's own body otherwise.
                    // Both go through the same note-blocks rendering.
                    NotesView(blocks: UpdateLogic.noteBlocks(controller.consolidatedNotes ?? manifest.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(controller.isVerifyingInstall ? "Verifying update…" : (staged ? "Signature verified · ready to install" : "Preparing the update…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Skip This Version") { controller.skipVersion(manifest.version) }
                .disabled(controller.isVerifyingInstall)
                .font(.system(size: 12))
                .help("Stop automatic offers for this version. Check for Updates can show it again.")
            Color.clear.frame(height: 8)
            footer(
                primaryTitle: "Install & Relaunch",
                primaryEnabled: staged && !controller.isVerifyingInstall,
                primaryAction: { controller.install() },
                cancelTitle: "Later"
            )
        }
    }

    /// Release body rendered as headings / bullets / paragraphs — real
    /// changelogs are multiple lists under headings, not one flat list.
    private struct NotesView: View {
        let blocks: [UpdateLogic.NoteBlock]

        var body: some View {
            if blocks.isEmpty {
                Text("Bug fixes and improvements.")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        switch block {
                        case .heading(let level, let text):
                            Text(text)
                                // Level 2 headings mark release boundaries in
                                // consolidated multi-version notes — a step
                                // larger, bolder, and with extra separation so
                                // each release's section reads as a block.
                                .font(.system(size: level == 3 ? 12 : 13, weight: level == 2 ? .bold : .semibold))
                                .foregroundStyle(.primary)
                                .padding(.top, level == 2 && index > 0 ? 8 : 0)
                                .textSelection(.enabled)
                        case .bullet(let text):
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(text.isEmpty ? " " : text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .textSelection(.enabled)
                            }
                        case .paragraph(let text):
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Update available (Homebrew-managed)

    /// Brew mode: discovery and notes stay, but the action is a copyable
    /// `brew upgrade` command. The pasteboard is written ONLY by the explicit
    /// button action — never on presentation.
    private func brewAvailableView(_ manifest: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("now \(manifest.version)")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Released \(manifest.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())) · currently on \(UpdateLogic.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT'S NEW")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                PopupScrollView {
                    NotesView(blocks: UpdateLogic.noteBlocks(controller.consolidatedNotes ?? manifest.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Managed by Homebrew")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(UpdateLogic.brewUpgradeCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                Text("This copy of now is installed and updated with Homebrew. Run the command in Terminal, then relaunch now — the running version stays \(UpdateLogic.currentVersion) until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Skip This Version") { controller.skipVersion(manifest.version) }
                .font(.system(size: 12))
                .help("Stop automatic offers for this version. Check for Updates can show it again.")
            Color.clear.frame(height: 8)
            footer(
                primaryTitle: brewCommandCopied ? "Copied" : "Copy Command",
                primaryEnabled: true,
                primaryAction: { copyBrewUpgradeCommand() },
                cancelTitle: "Later",
                // "Copied" is shorter than "Copy Command" — reserve the wider
                // title so the confirmation does not resize the button.
                primaryMinWidth: 124
            )
        }
    }

    /// Writes the upgrade command to the pasteboard on the explicit button
    /// action and briefly confirms it.
    @State private var brewCommandCopied = false

    private func copyBrewUpgradeCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(UpdateLogic.brewUpgradeCommand, forType: .string)
        brewCommandCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            brewCommandCopied = false
        }
    }

    // MARK: - Up to date

    private var upToDateView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("You're up to date")
                        .font(.system(size: 17, weight: .semibold))
                    Text("now \(UpdateLogic.currentVersion) is the latest version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Color.clear.frame(height: 8)
            footer(
                primaryTitle: "OK",
                primaryEnabled: true,
                primaryAction: { controller.dismissWindow() },
                cancelTitle: nil
            )
        }
    }

    // MARK: - Installed

    /// One-time confirmation shown once a successful install's startup has
    /// been health-acknowledged (the commit point) — until then the app is
    /// quietly back, leaving the user to guess whether the update worked.
    private func installedView(_ version: String, confirmedInstall: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmedInstall ? "Update installed" : "What’s New")
                        .font(.system(size: 17, weight: .semibold))
                    Text(confirmedInstall ? "now \(version) is installed and running." : "Discover new features in now \(version).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if confirmedInstall {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("Signature verified · update installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            if let guides = controller.store.featureGuides, let notifications = controller.store.notifications, !guides.updateIDs.isEmpty {
                // Card content grows up to its cap; navigation stays outside
                // the scrolling region.
                FeatureGuideView(store: controller.store, notifications: notifications, guides: guides, ids: guides.updateIDs, usesKeyboardShortcuts: true) {
                    controller.dismissWindow()
                }
            } else {
                Color.clear.frame(height: 8)
                footer(primaryTitle: "OK", primaryEnabled: true,
                       primaryAction: { controller.dismissWindow() }, cancelTitle: nil)
            }
        }
    }

    // MARK: - Problem

    private func problemView(title: String, message: String, retry: UpdateRetry?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PopupScrollView {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Color.clear.frame(height: 8)
            footer(
                primaryTitle: retry == nil ? "OK" : "Try Again",
                primaryEnabled: true,
                primaryAction: {
                    if let retry { controller.retry(retry) }
                    else { controller.dismissWindow() }
                },
                cancelTitle: retry == nil ? nil : "Cancel"
            )
        }
    }

    // MARK: - Shared pieces

    private var appIcon: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .frame(width: 64, height: 64)
    }

    /// Bottom bar: quiet "View on GitHub…" badge bottom-left (the same
    /// capsule style the Settings badges use — visibly clickable), buttons
    /// bottom-right. `primaryMinWidth` reserves the primary button's width so
    /// a transient label change cannot shift the layout (nil = intrinsic).
    @ViewBuilder
    private func footer(primaryTitle: String, primaryEnabled: Bool, primaryAction: @escaping () -> Void, cancelTitle: String?, primaryMinWidth: CGFloat? = nil) -> some View {
        HStack(alignment: .bottom) {
            BadgeLink(url: Links.releases) {
                Text("View on GitHub")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            Spacer()
            if let cancelTitle {
                Button(cancelTitle) { controller.dismissWindow() }
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                primaryAction()
            } label: {
                Text(primaryTitle)
                    .frame(minWidth: primaryMinWidth)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
        }
    }
}

/// Blurred window background matching the app's window chrome. Falls back to
/// the plain window background (the NSWindow is titled, so this is cosmetic).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
