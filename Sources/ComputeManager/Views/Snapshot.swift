#if DEBUG
import AppKit
import SwiftUI

/// Debug aid (`COMPUTEMANAGER_SNAPSHOT=<png>`): render the menu content in a plain window,
/// write it as PNG. Lets layout be checked without clicking the status item.
@MainActor
enum Snapshot {
    static func write(model: AppModel, to path: String) {
        let view = NSHostingView(rootView: MenuContent(model: model).background(.background))
        view.frame.size = view.fittingSize
        let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = view
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            view.frame.size = view.fittingSize
            win.setContentSize(view.fittingSize)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            win.orderOut(nil)
        }
    }
}
#endif
