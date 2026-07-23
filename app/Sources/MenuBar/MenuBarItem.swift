import AppKit
import CoreGraphics

struct MenuBarItem: Identifiable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleIdentifier: String?
    let title: String?
    let stableIdentifier: String?
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
        [bundleIdentifier ?? ownerName, stableIdentifier ?? title ?? ownerName]
            .joined(separator: "|")
    }

    var legacyStorageKey: String {
        [bundleIdentifier ?? ownerName, title ?? ownerName].joined(separator: "|")
    }

    var systemSymbolName: String? {
        guard
            bundleIdentifier == "com.apple.controlcenter" ||
            bundleIdentifier == "com.apple.systemuiserver"
        else { return nil }

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

    var logicalWidth: CGFloat {
        min(max(frame.width, 24), 52)
    }
}
