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

    func show(relativeTo button: NSStatusBarButton) {
        resizeToFit()
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(max(screen.visibleFrame.minX + 8, buttonFrame.midX - frame.width / 2), screen.visibleFrame.maxX - frame.width - 8)
        let y = buttonFrame.minY - frame.height - 5
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func resizeToFit() {
        let screenWidth = (NSScreen.main?.visibleFrame.width ?? 800) - 32
        let desiredWidth: CGFloat
        let desiredHeight: CGFloat

        if !model.canCaptureScreen || !model.canUseAccessibility {
            desiredWidth = 390
            desiredHeight = 174
        } else if model.isManaging {
            desiredWidth = 520
            desiredHeight = 154
        } else if model.barrItems.isEmpty {
            desiredWidth = 310
            desiredHeight = 74
        } else {
            desiredWidth = model.barrItems.reduce(62) { $0 + $1.logicalWidth + 8 }
            desiredHeight = 58
        }

        setContentSize(NSSize(width: min(desiredWidth, screenWidth), height: desiredHeight))
    }

    override var canBecomeKey: Bool { true }
}
