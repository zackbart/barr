import AppKit
import CoreGraphics

enum MenuBarScanner {
    static func scan() -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rawWindows = PrivateWindowServer.menuBarWindowIDs().compactMap(rawWindow)
        let sources = accessibilitySources()
        var claimedWindowIDs = Set<CGWindowID>()
        var items = [MenuBarItem]()

        // Tahoe reparents third-party status windows to Control Center. Match the
        // original app's Accessibility frame back to its WindowServer window.
        // Match the widest, most distinctive items first. On Tahoe the AX frame
        // describes the app's logical status item while WindowServer exposes a
        // padded/reflowed host window, so their centers are no longer identical.
        for source in sources.sorted(by: { $0.frame.width > $1.frame.width }) {
            guard let match = rawWindows
                .filter({ !claimedWindowIDs.contains($0.windowID) })
                .map({ ($0, matchCost($0.frame, source.frame)) })
                .filter({ $0.1 <= 220 })
                .min(by: { $0.1 < $1.1 })?.0
            else { continue }

            claimedWindowIDs.insert(match.windowID)
            items.append(makeItem(window: match, source: source))
        }

        // Pre-Tahoe and a few unusual helpers still own their status windows.
        for window in rawWindows where !claimedWindowIDs.contains(window.windowID) {
            guard
                window.ownerPID != ownPID,
                window.ownerName != "Window Server",
                let app = NSRunningApplication(processIdentifier: window.ownerPID),
                app.bundleIdentifier?.hasPrefix("com.apple.") != true
            else { continue }

            let source = AccessibilitySource(
                ownerPID: window.ownerPID,
                ownerName: app.localizedName ?? window.ownerName,
                bundleIdentifier: app.bundleIdentifier,
                title: window.title,
                frame: window.frame
            )
            items.append(makeItem(window: window, source: source))
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
        scan().first { $0.windowID == windowID }
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
        let frame: CGRect
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

    private static func makeItem(window: RawWindow, source: AccessibilitySource) -> MenuBarItem {
        MenuBarItem(
            windowID: window.windowID,
            ownerPID: source.ownerPID,
            ownerName: source.ownerName,
            bundleIdentifier: source.bundleIdentifier,
            title: source.title ?? window.title,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            image: capture(windowID: window.windowID)
        )
    }

    private static func accessibilitySources() -> [AccessibilitySource] {
        guard PermissionCenter.isAccessibilityGranted else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications.flatMap { app -> [AccessibilitySource] in
            guard
                app.processIdentifier != ownPID,
                !app.isTerminated,
                app.activationPolicy != .prohibited,
                app.bundleIdentifier?.hasPrefix("com.apple.") != true
            else { return [] }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            guard let extras = axElement(appElement, attribute: kAXExtrasMenuBarAttribute as CFString) else {
                return []
            }

            return axChildren(extras).compactMap { child in
                guard let frame = axFrame(child) else { return nil }
                return AccessibilitySource(
                    ownerPID: app.processIdentifier,
                    ownerName: app.localizedName ?? app.bundleIdentifier ?? "Menu bar app",
                    bundleIdentifier: app.bundleIdentifier,
                    title: axString(child, attribute: kAXTitleAttribute as CFString),
                    frame: frame
                )
            }
        }
    }

    private static func matchCost(_ window: CGRect, _ accessibility: CGRect) -> CGFloat {
        let horizontalDistance = abs(window.midX - accessibility.midX)
        let verticalDistance = abs(window.midY - accessibility.midY)
        let widthDifference = abs(window.width - accessibility.width)
        return horizontalDistance + verticalDistance * 4 + widthDifference * 2
    }

    private static func capture(windowID: CGWindowID) -> NSImage? {
        var rawWindow = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard
            let array = CFArrayCreate(kCFAllocatorDefault, &rawWindow, 1, nil),
            let image = CGImage.captureWindowList(array)
        else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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
