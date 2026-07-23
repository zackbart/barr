import AppKit
import CoreGraphics

struct MenuBarItem: Identifiable {
    static let visualIconHeight: CGFloat = 24
    static let iconHitTarget: CGFloat = 32

    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleIdentifier: String?
    let title: String?
    let stableIdentifier: String?
    let frame: CGRect
    let isOnScreen: Bool
    let image: NSImage?

    // WindowServer can replace or re-parent a status item's window while Barr
    // moves it. Its logical identity stays stable across those transitions.
    var id: String { storageKey }

    var displayName: String {
        guard let title, !title.isEmpty else { return ownerName }
        if ownerName == "Control Center" { return title }
        return ownerName
    }

    var storageKey: String {
        [bundleIdentifier ?? ownerName, stableIdentifier ?? title ?? ownerName]
            .joined(separator: "|")
    }

    var legacyStorageKey: String {
        [bundleIdentifier ?? ownerName, title ?? ownerName].joined(separator: "|")
    }

    var isSystemItem: Bool {
        bundleIdentifier == "com.apple.controlcenter" ||
            bundleIdentifier == "com.apple.systemuiserver"
    }

    var isMovableByBarr: Bool {
        guard isSystemItem else { return true }
        let identity = [stableIdentifier, title]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        // These are permanent macOS menu-bar surfaces rather than movable
        // status items. In particular, the clock owns Notification Center and
        // Apple documents that it is always present.
        return !identity.contains("control center") &&
            !identity.contains("clock") &&
            !identity.contains("audio and video controls")
    }

    var systemSymbolName: String? {
        guard isSystemItem else { return nil }

        let identity = [stableIdentifier, title]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if identity.contains("screen mirroring") || identity.contains("airplay") {
            return "rectangle.on.rectangle"
        }
        if identity.contains("keyboard brightness") { return "sun.max.fill" }
        if identity.contains("display") { return "display" }
        if identity.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
        if identity.contains("battery") { return "battery.100" }
        if identity.contains("spotlight") { return "magnifyingglass" }
        if identity.contains("sound") || identity.contains("volume") { return "speaker.wave.2.fill" }
        if identity.contains("wi-fi") || identity.contains("wi‑fi") || identity.contains("airport") {
            return "wifi"
        }
        if identity.contains("control center") { return "switch.2" }
        if identity.contains("clock") { return "clock" }
        if identity.contains("now playing") || identity.contains("audio and video") {
            return "video.fill"
        }
        if identity.contains("focus") { return "moon.fill" }
        if identity.contains("time machine") { return "clock.arrow.circlepath" }
        if identity.contains("user switching") { return "person.crop.circle" }
        if identity.contains("airdrop") { return "dot.radiowaves.left.and.right" }
        return nil
    }

    var renderedIconWidth: CGFloat {
        guard systemSymbolName == nil, let image, image.size.height > 0 else {
            return Self.visualIconHeight
        }
        let aspectRatio = min(max(image.size.width / image.size.height, 0.7), 2.6)
        return min(max(Self.visualIconHeight * aspectRatio, 18), 58)
    }

    var logicalWidth: CGFloat {
        max(renderedIconWidth, Self.iconHitTarget)
    }

    func replacingImage(_ image: NSImage) -> MenuBarItem {
        MenuBarItem(
            windowID: windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            stableIdentifier: stableIdentifier,
            frame: frame,
            isOnScreen: isOnScreen,
            image: image
        )
    }
}
