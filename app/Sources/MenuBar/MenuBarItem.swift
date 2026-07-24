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
    let storageKey: String
    let legacyStorageKey: String
    private let normalizedIdentity: String

    init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerName: String,
        bundleIdentifier: String?,
        title: String?,
        stableIdentifier: String?,
        frame: CGRect,
        isOnScreen: Bool,
        image: NSImage?
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.stableIdentifier = stableIdentifier
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.image = image
        storageKey = [bundleIdentifier ?? ownerName, stableIdentifier ?? title ?? ownerName]
            .joined(separator: "|")
        legacyStorageKey = [bundleIdentifier ?? ownerName, title ?? ownerName]
            .joined(separator: "|")
        normalizedIdentity = [stableIdentifier, title]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    // WindowServer can replace or re-parent a status item's window while Barr
    // moves it. Its logical identity stays stable across those transitions.
    var id: String { storageKey }

    var displayName: String {
        guard let title, !title.isEmpty else { return ownerName }
        if ownerName == "Control Center" { return title }
        return ownerName
    }

    var isSystemItem: Bool {
        bundleIdentifier == "com.apple.controlcenter" ||
            bundleIdentifier == "com.apple.systemuiserver"
    }

    var isMovableByBarr: Bool {
        guard isSystemItem else { return true }

        // These are permanent macOS menu-bar surfaces rather than movable
        // status items. In particular, the clock owns Notification Center and
        // Apple documents that it is always present.
        return !normalizedIdentity.contains("control center") &&
            !normalizedIdentity.contains("clock") &&
            !normalizedIdentity.contains("audio and video controls")
    }

    var systemSymbolName: String? {
        guard isSystemItem else { return nil }

        if normalizedIdentity.contains("screen mirroring") ||
            normalizedIdentity.contains("airplay")
        {
            return "rectangle.on.rectangle"
        }
        if normalizedIdentity.contains("keyboard brightness") { return "sun.max.fill" }
        if normalizedIdentity.contains("display") { return "display" }
        if normalizedIdentity.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
        if normalizedIdentity.contains("battery") { return "battery.100" }
        if normalizedIdentity.contains("spotlight") { return "magnifyingglass" }
        if normalizedIdentity.contains("sound") || normalizedIdentity.contains("volume") {
            return "speaker.wave.2.fill"
        }
        if
            normalizedIdentity.contains("wi-fi") ||
            normalizedIdentity.contains("wi‑fi") ||
            normalizedIdentity.contains("airport")
        {
            return "wifi"
        }
        if normalizedIdentity.contains("control center") { return "switch.2" }
        if normalizedIdentity.contains("clock") { return "clock" }
        if normalizedIdentity.contains("now playing") ||
            normalizedIdentity.contains("audio and video")
        {
            return "video.fill"
        }
        if normalizedIdentity.contains("focus") { return "moon.fill" }
        if normalizedIdentity.contains("time machine") { return "clock.arrow.circlepath" }
        if normalizedIdentity.contains("user switching") { return "person.crop.circle" }
        if normalizedIdentity.contains("airdrop") { return "dot.radiowaves.left.and.right" }
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

    func hasSameContent(as other: MenuBarItem) -> Bool {
        windowID == other.windowID &&
            ownerPID == other.ownerPID &&
            ownerName == other.ownerName &&
            bundleIdentifier == other.bundleIdentifier &&
            title == other.title &&
            stableIdentifier == other.stableIdentifier &&
            frame == other.frame &&
            isOnScreen == other.isOnScreen &&
            imagesAreIdentical(image, other.image)
    }

    private func imagesAreIdentical(_ lhs: NSImage?, _ rhs: NSImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs === rhs
        default:
            return false
        }
    }
}
