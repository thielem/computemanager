import AppKit
import SwiftUI

/// The menu bar UI is an `NSStatusItem` + `NSPopover` (`StatusItemController`), not a
/// `MenuBarExtra`: its window-style panel clipped its rounded top/bottom edges when the content
/// height changed. The `Settings` scene is never shown; it only gives SwiftUI a scene (and the
/// standard Edit menu key equivalents for the Settings window's text fields).
@main
struct ComputeManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppRuntime.launch()
            guard AppRuntime.launched else { return }  // duplicate instance: quitting
            statusItem = StatusItemController(model: AppRuntime.model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppRuntime.terminate() }
    }
}

/// Status item (state glyph) whose left click toggles a transient popover with `MenuContent`.
/// The popover follows the content's ideal size (`preferredContentSize`), so job rows and the
/// stop choice grow it instead of being clipped.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: MenuContent(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        trackIcon()
        #if DEBUG
        // Screenshot aid: open the popover like a click would and log its window number.
        if ProcessInfo.processInfo.environment["COMPUTEMANAGER_OPEN_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                item.button?.performClick(nil)
                NSLog("ComputeManager: popover window %d", popover.contentViewController?.view.window?.windowNumber ?? -1)
            }
        }
        #endif
    }

    /// Redraw the glyph whenever the observed model state changes.
    private func trackIcon() {
        withObservationTracking {
            item.button?.image = MenuBarIcon.image(for: model.icon)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)  // accessory app: needed for ⌘, / ⌘Q in the popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.gate.cancelOffChoice()  // a pending gate-off choice doesn't survive closing the menu
    }
}
