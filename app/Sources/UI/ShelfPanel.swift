import AppKit
import SwiftUI

@MainActor
final class ShelfPanel: NSPanel {
    private let model: ShelfModel
    private let hostingView: NSHostingView<ShelfView>

    init(model: ShelfModel) {
        self.model = model
        self.hostingView = NSHostingView(rootView: ShelfView(model: model))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 68),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Barr"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .mainMenu + 1
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace, .transient]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = hostingView
    }

    @discardableResult
    func show(relativeTo button: NSStatusBarButton) -> Bool {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else {
            return false
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard Self.isVisibleMenuBarFrame(buttonFrame, on: screen) else {
            close()
            return false
        }

        resizeToFit(on: screen)
        let minimumX = screen.visibleFrame.minX + 8
        let maximumX = max(minimumX, screen.visibleFrame.maxX - frame.width - 8)
        let x = min(max(minimumX, buttonFrame.midX - frame.width / 2), maximumX)
        let y = buttonFrame.minY - frame.height - 5
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        makeKey()
        return true
    }

    private static func isVisibleMenuBarFrame(_ frame: CGRect, on screen: NSScreen) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }

        let visibleWidth = screen.frame.intersection(frame).width
        guard visibleWidth >= min(frame.width * 0.8, frame.width - 1) else {
            return false
        }

        let menuBarAreas = [
            screen.auxiliaryTopLeftArea,
            screen.auxiliaryTopRightArea
        ].compactMap { $0 }
        guard !menuBarAreas.isEmpty else { return true }

        // A status item's NSWindow still has valid on-screen geometry while it
        // sits beneath a MacBook notch. Only anchor the shelf to an item that
        // actually intersects one of the visible menu-bar regions.
        return menuBarAreas.contains {
            $0.intersection(frame).width >= min(frame.width * 0.8, frame.width - 1)
        }
    }

    func resizeToFit(on targetScreen: NSScreen? = nil) {
        let sizingScreen = targetScreen ?? (isVisible ? screen : nil) ?? NSScreen.main
        let screenWidth = max((sizingScreen?.visibleFrame.width ?? 800) - 32, 200)
        let desiredWidth: CGFloat
        let desiredHeight: CGFloat

        if !model.canCaptureScreen || !model.canUseAccessibility {
            desiredWidth = 390
            desiredHeight = 174
        } else if model.isManaging {
            desiredWidth = 520
            desiredHeight = 210
        } else if model.barrItems.isEmpty {
            desiredWidth = 310
            desiredHeight = 74
        } else {
            desiredWidth = model.barrItems.reduce(62) { $0 + $1.logicalWidth + 8 }
            desiredHeight = 66
        }

        setContentSize(NSSize(width: min(desiredWidth, screenWidth), height: desiredHeight))
    }

    override var canBecomeKey: Bool { true }
}
