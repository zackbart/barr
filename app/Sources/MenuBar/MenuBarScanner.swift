import AppKit
import CoreGraphics

enum MenuBarScanner {
    private static let exclusionLock = NSLock()
    private static let scanLock = NSLock()
    private nonisolated(unsafe) static var excludedWindowIDs = Set<CGWindowID>()
    private nonisolated(unsafe) static var windowIDBySourceKey = [String: CGWindowID]()

    static func setExcludedWindowIDs(_ windowIDs: Set<CGWindowID>) {
        exclusionLock.lock()
        excludedWindowIDs = windowIDs
        exclusionLock.unlock()
    }

    static func scan(captureImages: Bool = true) -> [MenuBarItem] {
        scanLock.lock()
        defer { scanLock.unlock() }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        exclusionLock.lock()
        let excluded = excludedWindowIDs
        exclusionLock.unlock()
        let rawWindows = PrivateWindowServer.menuBarWindowIDs()
            .filter { !excluded.contains($0) }
            .compactMap(rawWindow)
        let sources = accessibilitySources().filter {
            $0.frame.width > 0 && $0.frame.height > 0
        }
        let activeSourceKeys = Set(sources.map(\.sourceKey))
        windowIDBySourceKey = windowIDBySourceKey.filter {
            activeSourceKeys.contains($0.key)
        }
        var claimedWindowIDs = Set<CGWindowID>()
        var items = [MenuBarItem]()

        // Tahoe reparents third-party status windows to Control Center. Match the
        // original app's Accessibility frame back to its WindowServer window.
        // Match the widest, most distinctive items first. On Tahoe the AX frame
        // describes the app's logical status item while WindowServer exposes a
        // padded/reflowed host window, so their centers are no longer identical.
        for source in sources.sorted(by: { $0.frame.width > $1.frame.width }) {
            let available = rawWindows.filter { !claimedWindowIDs.contains($0.windowID) }
            let previousMatch: RawWindow? = windowIDBySourceKey[source.sourceKey].flatMap { previousID in
                guard !claimedWindowIDs.contains(previousID) else { return nil }
                // WindowServer drops status-item windows from the menu-bar list
                // once Barr parks them beyond the screen edge. Their IDs and
                // private frames remain valid, so keep using that exact window
                // instead of relabelling a visible neighbor with similar geometry.
                let candidate = available.first { $0.windowID == previousID } ?? rawWindow(previousID)
                guard let candidate, matchCost(candidate.frame, source.frame) <= 320 else {
                    windowIDBySourceKey.removeValue(forKey: source.sourceKey)
                    return nil
                }
                return candidate
            }
            let geometricMatch = available
                .map { ($0, matchCost($0.frame, source.frame)) }
                .filter { $0.1 <= 220 }
                .min { $0.1 < $1.1 }?.0
            guard let match = previousMatch ?? geometricMatch else { continue }

            claimedWindowIDs.insert(match.windowID)
            windowIDBySourceKey[source.sourceKey] = match.windowID
            items.append(makeItem(window: match, source: source, captureImages: captureImages))
        }

        // Pre-Tahoe and a few unusual helpers still own their status windows.
        for window in rawWindows where !claimedWindowIDs.contains(window.windowID) {
            guard
                window.ownerPID != ownPID,
                window.ownerName != "Window Server",
                let app = NSRunningApplication(processIdentifier: window.ownerPID)
            else { continue }

            let source = AccessibilitySource(
                ownerPID: window.ownerPID,
                ownerName: app.localizedName ?? window.ownerName,
                bundleIdentifier: app.bundleIdentifier,
                title: window.title,
                stableIdentifier: nil,
                frame: window.frame
            )
            items.append(makeItem(window: window, source: source, captureImages: captureImages))
        }

        return items
            .sorted { lhs, rhs in
                if lhs.frame.minX == rhs.frame.minX {
                    return lhs.ownerName.localizedCaseInsensitiveCompare(rhs.ownerName) == .orderedAscending
                }
                return lhs.frame.minX < rhs.frame.minX
            }
    }

    static func item(windowID: CGWindowID) -> MenuBarItem? {
        scan(captureImages: false).first { $0.windowID == windowID }
    }

    private struct RawWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let title: String?
        let frame: CGRect
        let isOnScreen: Bool
    }

    private struct AccessibilitySource {
        let ownerPID: pid_t
        let ownerName: String
        let bundleIdentifier: String?
        let title: String?
        let stableIdentifier: String?
        let frame: CGRect

        var sourceKey: String {
            [bundleIdentifier ?? ownerName, stableIdentifier ?? title ?? ownerName]
                .joined(separator: "|")
        }
    }

    private static func rawWindow(_ windowID: CGWindowID) -> RawWindow? {
        let values = [windowID] as CFArray
        let description = (CGWindowListCreateDescriptionFromArray(values) as? [[CFString: Any]])?.first
        let describedFrame = (description?[kCGWindowBounds] as? NSDictionary)
            .flatMap(CGRect.init(dictionaryRepresentation:))
        guard let frame = PrivateWindowServer.frame(of: windowID) ?? describedFrame else { return nil }

        return RawWindow(
            windowID: windowID,
            ownerPID: description?[kCGWindowOwnerPID] as? pid_t ?? 0,
            ownerName: description?[kCGWindowOwnerName] as? String ?? "Menu bar app",
            title: description?[kCGWindowName] as? String,
            frame: frame,
            isOnScreen: description?[kCGWindowIsOnscreen] as? Bool ?? true
        )
    }

    private static func makeItem(
        window: RawWindow,
        source: AccessibilitySource,
        captureImages: Bool
    ) -> MenuBarItem {
        MenuBarItem(
            windowID: window.windowID,
            ownerPID: source.ownerPID,
            ownerName: source.ownerName,
            bundleIdentifier: source.bundleIdentifier,
            title: source.title ?? window.title,
            stableIdentifier: source.stableIdentifier,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            image: captureImages ? capture(windowID: window.windowID, source: source) : nil
        )
    }

    private static func accessibilitySources() -> [AccessibilitySource] {
        guard PermissionCenter.isAccessibilityGranted else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications.flatMap { app -> [AccessibilitySource] in
            let bundleIdentifier = app.bundleIdentifier
            let isSystemStatusProvider = bundleIdentifier == "com.apple.controlcenter" ||
                bundleIdentifier == "com.apple.systemuiserver"
            guard
                app.processIdentifier != ownPID,
                !app.isTerminated,
                app.activationPolicy != .prohibited
            else { return [] }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            guard let extras = axElement(appElement, attribute: kAXExtrasMenuBarAttribute as CFString) else {
                return []
            }

            let children = axChildren(extras).compactMap { child -> (AXUIElement, CGRect)? in
                guard let frame = axFrame(child), frame.width > 0, frame.height > 0 else {
                    return nil
                }
                return (child, frame)
            }
            let useBundleIdentity = !isSystemStatusProvider && children.count == 1

            return children.map { pair in
                let (child, frame) = pair
                let title = statusItemName(child, useSystemFallbacks: isSystemStatusProvider)
                let rawIdentifier = axString(child, attribute: kAXIdentifierAttribute as CFString)
                    .flatMap { $0.isEmpty ? nil : $0 }
                let stableIdentifier: String?
                if isSystemStatusProvider {
                    stableIdentifier = statusItemIdentifier(child)
                } else if let rawIdentifier {
                    stableIdentifier = rawIdentifier
                } else if useBundleIdentity {
                    stableIdentifier = ""
                } else {
                    stableIdentifier = title
                }

                return AccessibilitySource(
                    ownerPID: app.processIdentifier,
                    ownerName: app.localizedName ?? app.bundleIdentifier ?? "Menu bar app",
                    bundleIdentifier: bundleIdentifier,
                    title: title,
                    stableIdentifier: stableIdentifier,
                    frame: frame
                )
            }
        }
    }

    private static func statusItemName(
        _ element: AXUIElement,
        useSystemFallbacks: Bool
    ) -> String? {
        // Preserve third-party titles exactly. Some apps expose an empty title,
        // and that value is part of their identity in existing Barr installs.
        guard useSystemFallbacks else {
            return axString(element, attribute: kAXTitleAttribute as CFString)
        }

        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { axString(element, attribute: $0 as CFString) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func statusItemIdentifier(_ element: AXUIElement) -> String? {
        if
            let identifier = axString(element, attribute: kAXIdentifierAttribute as CFString),
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return identifier
        }

        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { axString(element, attribute: $0 as CFString) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let canonicalNames = [
            "Screen Mirroring", "Keyboard Brightness", "Control Center",
            "Now Playing", "Time Machine", "User Switching", "Bluetooth",
            "Spotlight", "Battery", "Wi-Fi", "Wi‑Fi", "Sound", "Display",
            "Focus", "AirDrop", "Clock", "VPN"
        ]
        return canonicalNames.first {
            label.localizedCaseInsensitiveContains($0)
        }
    }

    private static func matchCost(_ window: CGRect, _ accessibility: CGRect) -> CGFloat {
        let horizontalDistance = abs(window.midX - accessibility.midX)
        let verticalDistance = abs(window.midY - accessibility.midY)
        let widthDifference = abs(window.width - accessibility.width)
        return horizontalDistance + verticalDistance * 4 + widthDifference * 2
    }

    private static func capture(
        windowID: CGWindowID,
        source: AccessibilitySource
    ) -> NSImage? {
        if #available(macOS 26, *) {
            return owningApplicationIcon(for: source)
        }

        var rawWindow = UnsafeRawPointer(bitPattern: UInt(windowID))
        if
            let array = CFArrayCreate(kCFAllocatorDefault, &rawWindow, 1, nil),
            let image = CGImage.captureWindowList(array),
            hasVisiblePixels(image)
        {
            let frameSize = PrivateWindowServer.frame(of: windowID)?.size ?? .zero
            let pointSize = frameSize.width > 0 && frameSize.height > 0
                ? frameSize
                : NSSize(width: image.width, height: image.height)
            return NSImage(cgImage: image, size: pointSize)
        }

        // A failed or redacted capture should never become an empty hit target.
        return owningApplicationIcon(for: source)
    }

    private static func owningApplicationIcon(for source: AccessibilitySource) -> NSImage? {
        NSRunningApplication(processIdentifier: source.ownerPID)?.icon?.copy() as? NSImage
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let xStep = max(1, image.width / 16)
        let yStep = max(1, image.height / 16)

        for y in stride(from: 0, to: image.height, by: yStep) {
            for x in stride(from: 0, to: image.width, by: xStep) {
                if bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                    return true
                }
            }
        }
        return false
    }
}

private func axElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
        let positionRef,
        let sizeRef,
        CFGetTypeID(positionRef) == AXValueGetTypeID(),
        CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }

    let positionValue = unsafeDowncast(positionRef as AnyObject, to: AXValue.self)
    let sizeValue = unsafeDowncast(sizeRef as AnyObject, to: AXValue.self)
    var position = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(positionValue, .cgPoint, &position),
        AXValueGetValue(sizeValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

private func axString(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private protocol WindowListCapturing {
    init?(
        windowListFromArrayScreenBounds screenBounds: CGRect,
        windowArray: CFArray,
        imageOption: CGWindowImageOption
    )
}

private extension WindowListCapturing {
    static func captureWindowList(_ windowArray: CFArray) -> Self? {
        Self(
            windowListFromArrayScreenBounds: .null,
            windowArray: windowArray,
            imageOption: [.boundsIgnoreFraming, .bestResolution]
        )
    }
}

extension CGImage: WindowListCapturing {}
