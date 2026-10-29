import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageTrailing
        }
        statusItem = item

        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        model.$menuBarState
            .removeDuplicates()
            .sink { [weak self] state in self?.render(state) }
            .store(in: &subscriptions)
        render(model.menuBarState)
        model.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.popoverWillShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverDidClose()
    }

    private func render(_ state: MenuBarState) {
        guard let button = statusItem?.button else { return }
        // The percentage sits to the left of the battery, as in macOS's own menu bar item.
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true
        if state.problem {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                accessibilityDescription: "Welll needs attention")
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = StatusIcon.image(percent: state.percent,
                                            limit: state.showLimitMarker ? state.limit : nil,
                                            charging: state.charging,
                                            pluggedIn: state.pluggedIn,
                                            lowPower: state.lowPower)
        }
        if state.showPercent, !state.problem, let percent = state.percent {
            // Tabular digits, so the icon doesn't shift as the number changes.
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.attributedTitle = NSAttributedString(
                string: "\(percent)%",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)])
        } else {
            button.title = ""
        }
        button.toolTip = state.tooltip
    }
}
