import AppKit
import Combine
import SwiftUI

/// A borderless window allowed to sit over the menu bar. It never takes keyboard focus.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI content, reports hover, and lets the first click land on a button
/// even though the window is never active.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchPanelController {
    private let model: AppModel
    private let panel: NotchPanel
    private var bag = Set<AnyCancellable>()
    private var collapse: DispatchWorkItem?
    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Set after isFloatingPanel, which would otherwise reset the level to "floating" (below the menu bar).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isReleasedWhenClosed = false

        let host = HoverHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host

        model.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.layout() }
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.layout() }
            }
            .store(in: &bag)

        // A click that lands in any other app closes the panel. Clicks inside the panel are
        // ours and never reach this monitor.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collapse?.cancel()
                self?.model.dismissPanel()
            }
        }

        layout()
    }

    private func hoverChanged(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            if !model.hovering { model.hovering = true }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.hovering else { return }
            self.model.hovering = false
        }
        collapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// The built-in display if it has a notch, otherwise the screen with the menu bar.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func metrics(for screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = (left > 0 && right > 0) ? screen.frame.width - left - right : 200
            return NotchMetrics(hasNotch: true, notchWidth: width, barHeight: top)
        }
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchMetrics(hasNotch: false, notchWidth: 0, barHeight: bar)
    }

    /// Extra transparent room around the shape, so the spring can overshoot without being cut off.
    private static let slack = CGSize(width: 24, height: 16)
    private var trim: DispatchWorkItem?

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// The size the window should settle at for the current state, or nil to hide it.
    private func settledSize() -> CGSize? {
        let size = model.expanded ? NotchLayout.expandedSize(model) : NotchLayout.collapsedSize(model)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGSize(width: size.width + Self.slack.width, height: size.height + Self.slack.height)
    }

    private func layout() {
        guard model.showPanel, let screen = targetScreen() else {
            panel.orderOut(nil)
            return
        }
        let m = metrics(for: screen)
        if model.metrics != m {
            model.metrics = m // triggers another layout pass with the new numbers
            return
        }
        guard let settled = settledSize() else {
            trim?.cancel()
            panel.orderOut(nil)
            return
        }
        // Grow at once so the animation has room; shrink only after it has finished.
        // The window itself never animates: the shape inside it does.
        let current = panel.isVisible ? panel.frame.size : .zero
        let roomy = CGSize(width: max(current.width, settled.width), height: max(current.height, settled.height))
        let roomyFrame = frame(for: roomy, on: screen)
        if panel.frame != roomyFrame { panel.setFrame(roomyFrame, display: true) }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            Log.write("fixed layer: \(FixedSpace.pin(panel))")
        }

        trim?.cancel()
        if roomy != settled {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.trimToSettled() }
            }
            trim = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
        snapshotIfAsked()
    }

    private func trimToSettled() {
        guard panel.isVisible, let screen = targetScreen(), let settled = settledSize() else { return }
        let target = frame(for: settled, on: screen)
        if panel.frame != target { panel.setFrame(target, display: true) }
        // If the window shrank away from under a still pointer, no "exited" event arrives.
        if model.hovering, !panel.frame.contains(NSEvent.mouseLocation) { hoverChanged(false) }
    }

    /// Debug aid: when PERCH_SNAPSHOT names a file, save a picture of the panel there after each change.
    private func snapshotIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["PERCH_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let view = self?.panel.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
