import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ShelfModel()
    private var statusItem: NSStatusItem!
    private var storageAnchor: NSStatusItem!
    private var shelfPanel: ShelfPanel!
    private var returnMonitor: Any?
    private var returnFallback: DispatchWorkItem?
    private var pendingReturn: (() -> Void)?
    private let collapsedStorageLength: CGFloat = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItems()
        shelfPanel = ShelfPanel(model: model)
        model.onItemsChanged = { [weak self] in
            self?.shelfPanel.resizeToFit()
            self?.updateStorageState()
        }
        model.onActivate = { [weak self] item in
            self?.activateFromShelf(item)
        }
        model.onRestart = { [weak self] in
            self?.restartApplication()
        }
        model.onMembershipChange = { [weak self] item, moveToBarr, completion in
            self?.changeMembership(of: item, moveToBarr: moveToBarr, completion: completion)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(environmentChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(environmentChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        model.refresh()

        if model.movedItemKeys.isEmpty {
            model.setManaging(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.showShelf()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        returnHiddenItemNow()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func activateFromShelf(_ item: MenuBarItem) {
        guard
            let controlWindowID = windowID(for: statusItem),
            let controlFrame = PrivateWindowServer.frame(of: controlWindowID),
            let returnDestination = returnDestination(for: item)
        else {
            model.activationFailed = !MenuBarActivator.activate(item)
            return
        }

        returnHiddenItemNow()
        shelfPanel.close()
        let revealPoint = CGPoint(x: controlFrame.minX - 1, y: controlFrame.midY)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let moved = MenuBarMover.move(
                windowID: item.windowID,
                sourcePID: item.ownerPID,
                beside: controlWindowID,
                at: revealPoint
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard let self else { return }
                let currentItem = MenuBarScanner.item(windowID: item.windowID) ?? item
                let activated = moved && MenuBarActivator.activate(currentItem)
                self.model.activationFailed = !activated
                guard moved else { return }
                self.armReturn(
                    item: item,
                    anchorWindowID: returnDestination.windowID,
                    returnPoint: returnDestination.point
                )
            }
        }
    }

    private func returnDestination(for item: MenuBarItem) -> (windowID: CGWindowID, point: CGPoint)? {
        PrivateWindowServer.menuBarWindowIDs()
            .filter { $0 != item.windowID }
            .compactMap { windowID -> (windowID: CGWindowID, frame: CGRect)? in
                guard let frame = PrivateWindowServer.frame(of: windowID) else { return nil }
                return (windowID, frame)
            }
            .filter { $0.frame.midX > item.frame.midX }
            .min { $0.frame.midX < $1.frame.midX }
            .map { destination in
                (
                    windowID: destination.windowID,
                    point: CGPoint(x: destination.frame.minX - 1, y: destination.frame.midY)
                )
            }
    }

    private func armReturn(item: MenuBarItem, anchorWindowID: CGWindowID, returnPoint: CGPoint) {
        pendingReturn = {
            DispatchQueue.global(qos: .utility).async {
                _ = MenuBarMover.move(
                    windowID: item.windowID,
                    sourcePID: item.ownerPID,
                    beside: anchorWindowID,
                    at: returnPoint
                )
            }
        }

        returnMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.returnHiddenItemNow()
            }
        }

        let fallback = DispatchWorkItem { [weak self] in self?.returnHiddenItemNow() }
        returnFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: fallback)
    }

    private func returnHiddenItemNow() {
        if let returnMonitor {
            NSEvent.removeMonitor(returnMonitor)
            self.returnMonitor = nil
        }
        returnFallback?.cancel()
        returnFallback = nil
        let action = pendingReturn
        pendingReturn = nil
        action?()
    }

    private func restartApplication() {
        let bundlePath = Bundle.main.bundlePath
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 0.8; /usr/bin/open -n \"$1\"",
            "barr-relauncher",
            bundlePath
        ]

        do {
            try relauncher.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    private func changeMembership(
        of item: MenuBarItem,
        moveToBarr: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard PermissionCenter.isAccessibilityGranted else {
            PermissionCenter.requestAccessibility()
            completion(false)
            return
        }

        storageAnchor.length = collapsedStorageLength
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let anchorItem = moveToBarr ? self.storageAnchor : self.statusItem
            guard
                let anchorWindowID = self.windowID(for: anchorItem),
                let anchorFrame = PrivateWindowServer.frame(of: anchorWindowID)
            else {
                completion(false)
                self.updateStorageState()
                return
            }

            let targetPoint = CGPoint(x: anchorFrame.minX - 1, y: anchorFrame.midY)
            DispatchQueue.global(qos: .userInitiated).async {
                let moved = MenuBarMover.move(
                    windowID: item.windowID,
                    sourcePID: item.ownerPID,
                    beside: anchorWindowID,
                    at: targetPoint
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    completion(moved)
                    self.updateStorageState()
                    self.model.refresh()
                }
            }
        }
    }

    private func updateStorageState() {
        guard storageAnchor != nil else { return }
        guard !model.barrItems.isEmpty else {
            storageAnchor.length = collapsedStorageLength
            return
        }

        // Never expand the parking lane if it could affect an unselected icon.
        storageAnchor.length = collapsedStorageLength
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let windowID = self.windowID(for: self.storageAnchor),
                let anchorFrame = PrivateWindowServer.frame(of: windowID)
            else { return }

            let everyMenuBarItemIsSafe = self.model.menuBarItems.allSatisfy {
                $0.frame.midX > anchorFrame.midX
            }
            self.storageAnchor.length = everyMenuBarItemIsSafe ? 10_000 : self.collapsedStorageLength
        }
    }

    private func configureStatusItems() {
        setPreferredPosition(0, autosaveName: "BarrControl")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "BarrControl"
        statusItem.button?.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: "Barr overflow shelf"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemPressed(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        statusItem.button?.toolTip = "Barr"

        // A far-left parking boundary. It remains zero-width until at least one
        // explicitly selected item has been moved to its left.
        setPreferredPosition(1_000_000_000, autosaveName: "BarrStorageAnchor", force: true)
        storageAnchor = NSStatusBar.system.statusItem(withLength: collapsedStorageLength)
        storageAnchor.autosaveName = "BarrStorageAnchor"
        storageAnchor.button?.image = nil
        storageAnchor.button?.title = ""
        storageAnchor.button?.toolTip = "Barr storage boundary"
    }

    private func setPreferredPosition(
        _ position: CGFloat,
        autosaveName: String,
        force: Bool = false
    ) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if force || UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
        }
    }

    private func windowID(for item: NSStatusItem?) -> CGWindowID? {
        guard let button = item?.button, let window = button.window else { return nil }

        let number = window.windowNumber
        if
            number > 0,
            let windowID = CGWindowID(exactly: number),
            PrivateWindowServer.frame(of: windowID) != nil
        {
            return windowID
        }

        // Tahoe hosts status items in another process, so NSWindow.windowNumber
        // can be -1. Resolve our item from its horizontal screen geometry.
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return PrivateWindowServer.menuBarWindowIDs()
            .compactMap { windowID -> (CGWindowID, CGFloat)? in
                guard let frame = PrivateWindowServer.frame(of: windowID), frame.width < 240 else {
                    return nil
                }
                let score = abs(frame.midX - buttonFrame.midX) + abs(frame.width - buttonFrame.width) * 2
                return (windowID, score)
            }
            .filter { $0.1 < 100 }
            .min { $0.1 < $1.1 }?
            .0
    }

    @objc private func statusItemPressed(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggleShelf()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            toggleShelf()
        }
    }

    private func toggleShelf() {
        shelfPanel.isVisible ? shelfPanel.close() : showShelf()
    }

    private func showShelf() {
        guard let button = statusItem.button else { return }
        model.refresh()
        shelfPanel.show(relativeTo: button)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh icons", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Screen Recording settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Barr", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func environmentChanged() {
        shelfPanel?.close()
        model.refresh()
    }

    @objc private func refresh() {
        model.refresh()
    }

    @objc private func openScreenRecordingSettings() {
        PermissionCenter.openScreenRecordingSettings()
    }

    @objc private func openAccessibilitySettings() {
        PermissionCenter.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
