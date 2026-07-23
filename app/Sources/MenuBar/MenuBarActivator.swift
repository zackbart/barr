import AppKit
import ApplicationServices

enum MenuBarActivator {
    static func activate(_ item: MenuBarItem) -> Bool {
        guard PermissionCenter.isAccessibilityGranted else {
            PermissionCenter.requestAccessibility()
            return false
        }

        let application = AXUIElementCreateApplication(item.ownerPID)
        guard let extrasMenu = elementAttribute(application, kAXExtrasMenuBarAttribute as CFString) else {
            return fallbackClick(item)
        }

        let elements = descendants(of: extrasMenu, maximumDepth: 4)
        let matching = elements
            .compactMap { element -> (AXUIElement, CGFloat)? in
                guard let frame = frame(of: element) else { return nil }
                let dx = frame.midX - item.frame.midX
                let dy = frame.midY - item.frame.midY
                let distance = hypot(dx, dy)
                let overlaps = frame.intersects(item.frame) || distance < max(item.frame.width, 30)
                return overlaps ? (element, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0

        if let matching, AXUIElementPerformAction(matching, kAXPressAction as CFString) == .success {
            return true
        }
        return fallbackClick(item)
    }

    private static func fallbackClick(_ item: MenuBarItem) -> Bool {
        guard item.isOnScreen else { return false }
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func descendants(of root: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
        guard maximumDepth > 0 else { return [root] }
        let children = elementArrayAttribute(root, kAXChildrenAttribute as CFString)
        return [root] + children.flatMap { descendants(of: $0, maximumDepth: maximumDepth - 1) }
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as! AXUIElement?)
    }

    private static func elementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = valueAttribute(element, kAXPositionAttribute as CFString),
            let sizeValue = valueAttribute(element, kAXSizeAttribute as CFString),
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetType(sizeValue) == .cgSize
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func valueAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as! AXValue?
    }
}
