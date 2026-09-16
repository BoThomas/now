import AppKit
import SwiftUI

/// Content-sized popup scrolling. A native scrollbar stays visible whenever
/// content overflows, without reserving a track for short pages.
struct PopupScrollView<Content: View>: NSViewRepresentable {
    var maximumHeight: CGFloat = 320
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> PopupScrollContainer {
        PopupScrollContainer()
    }

    func updateNSView(_ view: PopupScrollContainer, context: Context) {
        view.content = AnyView(content())
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopupScrollContainer, context: Context) -> CGSize? {
        let width = proposal.width ?? 420
        nsView.maximumHeight = maximumHeight
        let height = nsView.measure(width: width)
        return CGSize(width: width, height: min(height, maximumHeight))
    }
}

final class PopupScrollContainer: NSScrollView {
    var content = AnyView(EmptyView())
    var maximumHeight: CGFloat = 320
    private let host = PopupDocumentView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .legacy
        borderType = .noBorder
        documentView = host
    }

    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat) -> CGFloat {
        // Measure without a gutter first. Only overflowing content needs the
        // narrower document width; the second measurement includes rewrapping.
        func fit(documentWidth: CGFloat) -> CGFloat {
            host.rootView = AnyView(content
                .frame(width: max(1, documentWidth - 8), alignment: .leading)
                .padding(.trailing, 8)
                .fixedSize(horizontal: false, vertical: true))
            return ceil(host.fittingSize.height)
        }
        var documentWidth = width
        var height = fit(documentWidth: documentWidth)
        if height > maximumHeight {
            documentWidth -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            height = fit(documentWidth: documentWidth)
        }
        host.setFrameSize(NSSize(width: max(1, documentWidth), height: height))
        return height
    }

    override func layout() {
        super.layout()
        // The document always retains its full height, independently of the
        // viewport. This is what makes the last row reachable by scrolling.
        _ = measure(width: bounds.width)
    }
}

/// SwiftUI's hosting view can consume wheel events even without a SwiftUI
/// ScrollView. The enclosing native scroll view owns scrolling in this bridge.
private final class PopupDocumentView: NSHostingView<AnyView> {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}

/// Let the hosting window follow the view's intrinsic height, preserving its
/// top edge when a page or update state changes. No installed-app state involved.
struct PopupWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) { view.scheduleResize() }

    final class SizingView: NSView {
        override func viewDidMoveToWindow() { scheduleResize() }
        override func layout() { super.layout(); scheduleResize() }

        func scheduleResize() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, let content = window.contentView else { return }
                let size = content.fittingSize
                guard size.width > 0, size.height > 0 else { return }
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                if let screen = window.screen?.visibleFrame {
                    frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
                }
                if abs(window.frame.height - frame.height) > 0.5 || abs(window.frame.width - frame.width) > 0.5 {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }
}
