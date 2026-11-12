import AppKit
import SwiftUI

/// Plain AppKit entry, no SwiftUI `App`: the menu bar UI is an `NSStatusItem` + `NSPopover`
/// (`StatusItemController`; a `MenuBarExtra` window clipped its rounded edges on resize), and a
/// SwiftUI `App` without a `MenuBarExtra` needs some other scene, which SwiftUI opens at launch
/// (an empty "Compute Manager Settings" window from a placeholder `Settings` scene).
@main
enum ComputeManagerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Never visible (accessory app), but provides ⌘Q and the standard Edit key equivalents
    /// for the Settings window. ⌘, / ⌘Q in the popover come from `MenuContent`'s buttons.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Compute Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for sub in [appMenu, edit] {
            let item = NSMenuItem()
            item.submenu = sub
            main.addItem(item)
        }
        return main
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
}
