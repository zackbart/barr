import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionCenter {
    static var hasScreenCaptureAuthorization: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var canCaptureScreen: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestScreenCapture(completion: @escaping (Bool) -> Void) {
        // TCC presents the system consent UI for this call. Keep it on the main
        // thread so the prompt is attached to Barr instead of being suppressed.
        completion(CGRequestScreenCaptureAccess())
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func openSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
