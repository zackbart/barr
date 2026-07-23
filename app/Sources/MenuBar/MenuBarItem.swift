import AppKit
import CoreGraphics

struct MenuBarItem: Identifiable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleIdentifier: String?
    let title: String?
    let frame: CGRect
    let isOnScreen: Bool
    let image: NSImage?

    var id: CGWindowID { windowID }

    var displayName: String {
        guard let title, !title.isEmpty else { return ownerName }
        if ownerName == "Control Center" { return title }
        return ownerName
    }

    var storageKey: String {
        [bundleIdentifier ?? ownerName, title ?? ownerName].joined(separator: "|")
    }

    var logicalWidth: CGFloat {
        min(max(frame.width, 24), 52)
    }
}
