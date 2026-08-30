import SwiftUI
import AppKit

/// The update window content — one window class, three states (available /
/// up to date / problem). Plain SwiftUI keyboard shortcuts are safe here:
/// both buttons always exist, so the alert's vanishing-button keyMonitor
/// machinery is deliberately not used. No HTML/JS in release notes, ever.
struct UpdateView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.windowContent {
            case .available(let manifest):
                availableView(manifest)
            case .upToDate:
                upToDateView
            case .problem(let title, let message, let retry):
                problemView(title: title, message: message, retry: retry)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .background(VisualEffectBackground())
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
                ScrollView {
                    NotesView(blocks: UpdateLogic.noteBlocks(manifest.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(staged ? "Signature verified · ready to install" : "Preparing the update…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            footer(
                primaryTitle: "Install & Relaunch",
                primaryEnabled: staged,
                primaryAction: { controller.install() },
                cancelTitle: "Later"
            )
        }
        .frame(height: 380, alignment: .topLeading)
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
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let level, let text):
                            Text(text)
                                .font(.system(size: level == 1 ? 13 : 12, weight: .semibold))
                                .foregroundStyle(.primary)
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
            Spacer(minLength: 8)
            footer(
                primaryTitle: "OK",
                primaryEnabled: true,
                primaryAction: { controller.dismissWindow() },
                cancelTitle: nil
            )
        }
        .frame(height: 380, alignment: .topLeading)
    }

    // MARK: - Problem

    private func problemView(title: String, message: String, retry: UpdateRetry?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
            Spacer(minLength: 8)
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
        .frame(height: 380, alignment: .topLeading)
    }

    // MARK: - Shared pieces

    private var appIcon: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .frame(width: 64, height: 64)
    }

    /// Bottom bar: quiet "View on GitHub…" badge bottom-left (the same
    /// capsule style the Settings badges use — visibly clickable), buttons
    /// bottom-right.
    @ViewBuilder
    private func footer(primaryTitle: String, primaryEnabled: Bool, primaryAction: @escaping () -> Void, cancelTitle: String?) -> some View {
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
