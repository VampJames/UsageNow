import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = UsageStore()

    private var statusItem: NSStatusItem?
    private let mainPopover = NSPopover()
    private let hoverPopover = NSPopover()
    private var hoverTimer: Timer?
    private var storeObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopovers()
        configureStatusItem()
        observeUsageChanges()
        store.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hoverTimer?.invalidate()
        store.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func configurePopovers() {
        mainPopover.behavior = .transient
        mainPopover.contentSize = NSSize(width: 460, height: 340)
        mainPopover.contentViewController = NSHostingController(rootView: MenuBarContentView(store: store))
        mainPopover.delegate = self

        hoverPopover.behavior = .applicationDefined
        hoverPopover.contentSize = NSSize(width: 260, height: 150)
        hoverPopover.contentViewController = NSHostingController(rootView: StatusBarHoverView(store: store))
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 45)
        guard let button = item.button else { return }

        button.image = makeStatusImage()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("UsageNow")
        button.setAccessibilityHelp(hoverDetails)

        let tracker = StatusBarHoverTracker(frame: button.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in self?.scheduleHoverDetails() }
        tracker.onExit = { [weak self] in self?.hideHoverDetails() }
        button.addSubview(tracker)

        item.isVisible = true
        statusItem = item
    }

    private func observeUsageChanges() {
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusItem()
            }
        }
    }

    private func refreshStatusItem() {
        statusItem?.button?.image = makeStatusImage()
        statusItem?.button?.setAccessibilityHelp(hoverDetails)
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            NSApp.terminate(nil)
            return
        }

        hoverTimer?.invalidate()
        hoverPopover.close()
        if mainPopover.isShown {
            mainPopover.performClose(sender)
        } else {
            showMainPopover()
        }
    }

    private func showMainPopover() {
        guard !mainPopover.isShown, let button = statusItem?.button else { return }
        hoverTimer?.invalidate()
        hoverPopover.close()
        store.setPopoverOpen(true)
        mainPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleHoverDetails() {
        guard !mainPopover.isShown else { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showHoverDetails()
            }
        }
    }

    private func showHoverDetails() {
        guard !mainPopover.isShown,
              !hoverPopover.isShown,
              let button = statusItem?.button else { return }
        hoverPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hideHoverDetails() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverPopover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as AnyObject? === mainPopover {
            store.setPopoverOpen(false)
        }
    }

    private var hoverDetails: String {
        [
            detail(name: "Codex", state: store.codexState, includesReset: true),
            detail(name: "Cursor", state: store.cursorState, includesReset: false),
        ].joined(separator: "\n")
    }

    private func detail(name: String, state: ProviderState, includesReset: Bool) -> String {
        guard let snapshot = snapshot(from: state) else {
            if case .unavailable(let message) = state {
                return "\(name)：\(message)"
            }
            return "\(name)：加载中…"
        }

        let inner = PercentageFormatter.remainingDisplayText(for: snapshot.innerMetric.percentUsed)
        let outer = PercentageFormatter.remainingDisplayText(for: snapshot.outerMetric.percentUsed)
        var text = "\(name)：\(snapshot.innerMetric.title)剩余 \(inner)，\(snapshot.outerMetric.title)剩余 \(outer)"
        if includesReset {
            text += "\n5 小时重置：\(ResetTimeFormatter.format(resetAt: snapshot.innerMetric.resetAt))"
            text += "；周额度重置：\(ResetTimeFormatter.format(resetAt: snapshot.outerMetric.resetAt))"
        }
        return text
    }

    private func snapshot(from state: ProviderState) -> UsageSnapshot? {
        switch state {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        default:
            return nil
        }
    }

    private func ringProgress(from state: ProviderState) -> (inner: Double, outer: Double)? {
        guard let snapshot = snapshot(from: state) else { return nil }
        return (
            PercentageFormatter.remainingRingProgress(for: snapshot.innerMetric.percentUsed),
            PercentageFormatter.remainingRingProgress(for: snapshot.outerMetric.percentUsed)
        )
    }

    private func makeStatusImage() -> NSImage {
        let codex = ringProgress(from: store.codexState)
        let cursor = ringProgress(from: store.cursorState)
        let image = NSImage(size: NSSize(width: 41, height: 18), flipped: false) { _ in
            Self.drawDoubleRing(
                center: NSPoint(x: 9, y: 9),
                progress: codex,
                innerColor: NSColor(red: 0.2, green: 0.75, blue: 0.65, alpha: 1),
                outerColor: NSColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1)
            )
            Self.drawDoubleRing(
                center: NSPoint(x: 32, y: 9),
                progress: cursor,
                innerColor: .systemOrange,
                outerColor: .systemPurple
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawDoubleRing(
        center: NSPoint,
        progress: (inner: Double, outer: Double)?,
        innerColor: NSColor,
        outerColor: NSColor
    ) {
        drawRing(center: center, radius: 7.2, lineWidth: 2.2, progress: progress?.outer, color: outerColor)
        drawRing(center: center, radius: 3.8, lineWidth: 1.8, progress: progress?.inner, color: innerColor)
    }

    private static func drawRing(
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        progress: Double?,
        color: NSColor
    ) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(progress == nil ? 0.14 : 0.22).setStroke()
        track.stroke()

        guard let progress, progress > 0 else { return }
        let arc = NSBezierPath()
        if progress >= 0.9999 {
            arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        } else {
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - (360 * progress),
                clockwise: true
            )
            arc.lineCapStyle = .round
        }
        arc.lineWidth = lineWidth
        color.setStroke()
        arc.stroke()
    }
}
