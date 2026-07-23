import CoreGraphics

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ capacity: Int32,
    _ windows: UnsafeMutablePointer<CGWindowID>,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(
    _ connection: CGSConnectionID,
    _ window: CGWindowID,
    _ rect: inout CGRect
) -> CGError

enum PrivateWindowServer {
    static func menuBarWindowIDs() -> [CGWindowID] {
        let connection = CGSMainConnectionID()
        var capacity: Int32 = 0
        guard CGSGetWindowCount(connection, 0, &capacity) == .success, capacity > 0 else {
            return []
        }

        var windows = [CGWindowID](repeating: 0, count: Int(capacity))
        var count: Int32 = 0
        let result = windows.withUnsafeMutableBufferPointer { buffer in
            CGSGetProcessMenuBarWindowList(connection, 0, capacity, buffer.baseAddress!, &count)
        }
        guard result == .success, count > 0 else { return [] }
        return Array(windows.prefix(Int(count)))
    }

    static func frame(of windowID: CGWindowID) -> CGRect? {
        var frame = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), windowID, &frame) == .success else {
            return nil
        }
        return frame
    }
}
