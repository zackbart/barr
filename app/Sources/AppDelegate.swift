import AppKit
import ApplicationServices
import OSLog

private let barrMembershipLogger = Logger(
    subsystem: "com.cursorkittens.Barr",
    category: "Membership"
)
private let barrActivationLogger = Logger(
    subsystem: "com.cursorkittens.Barr",
    category: "Activation"
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ShelfModel()
    private var statusItem: NSStatusItem!
    private var storageAnchor: NSStatusItem!
    private var shelfPanel: ShelfPanel!
    private var returnMonitor: Any?
    private var returnFallback: DispatchWorkItem?
    private var pendingReturn: (() -> Void)?
    private var shelfGlobalDismissMonitor: Any?
    private var shelfLocalDismissMonitor: Any?
    private var storageUpdateGeneration = 0
    private var handledInitialRefresh = false
    private var startupReconciliationComplete = false
    private var startupShelfRequested = false
    private var persistedItemReconciliationInProgress = false
    private var runningApplicationsGeneration = 0
    private let collapsedStorageLength: CGFloat = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItems()
        startupReconciliationComplete = model.movedItemKeys.isEmpty
        refreshScannerExclusions()
        shelfPanel = ShelfPanel(model: model)
        model.onItemsChanged = { [weak self] in
            self?.itemsChanged()
        }
        model.onRefreshCompleted = { [weak self] in
            self?.refreshCompleted()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(runningApplicationsChanged),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(runningApplicationsChanged),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        if model.movedItemKeys.isEmpty {
            model.setManaging(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refreshScannerExclusions()
            self?.model.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.requestStartupShelf()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        returnHiddenItemNow()
        removeShelfDismissMonitors()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showShelf()
        return true
    }

    private func itemsChanged() {
        shelfPanel.resizeToFit()
        if startupReconciliationComplete {
            updateStorageState()
        } else {
            storageAnchor.length = collapsedStorageLength
            refreshScannerExclusions()
        }
    }

    private func refreshCompleted() {
        if !handledInitialRefresh {
            handledInitialRefresh = true
        }

        if startupReconciliationComplete {
            reconcileNewlyVisiblePersistedItems()
            presentStartupShelfIfReady()
            return
        }

        // Keep the parking boundary collapsed until Accessibility becomes
        // available. The permissions UI must still be reachable, and the next
        // successful permission refresh will resume restoration automatically.
        guard PermissionCenter.isAccessibilityGranted else {
            presentStartupShelfIfReady()
            return
        }
        restorePersistedItemsAfterLaunch()
    }

    private func restorePersistedItemsAfterLaunch() {
        guard !persistedItemReconciliationInProgress else { return }
        persistedItemReconciliationInProgress = true
        storageAnchor.length = collapsedStorageLength
        refreshScannerExclusions()

        guard
            PermissionCenter.isAccessibilityGranted,
            let anchorWindowID = windowID(for: storageAnchor)
        else {
            persistedItemReconciliationInProgress = false
            finishStartupReconciliation()
            return
        }

        let persistedItems = model.barrItems.filter(\.isMovableByBarr)
        guard !persistedItems.isEmpty else {
            persistedItemReconciliationInProgress = false
            finishStartupReconciliation()
            return
        }

        reconcile(
            persistedItems,
            beside: anchorWindowID
        ) { [weak self] _ in
            guard let self else { return }
            self.persistedItemReconciliationInProgress = false
            self.finishStartupReconciliation()
        }
    }

    private func finishStartupReconciliation() {
        startupReconciliationComplete = true
        model.refresh()
        updateStorageState()
        presentStartupShelfIfReady()
    }

    private func reconcileNewlyVisiblePersistedItems() {
        guard
            !persistedItemReconciliationInProgress,
            PermissionCenter.isAccessibilityGranted,
            let anchorWindowID = windowID(for: storageAnchor)
        else { return }

        let anchorFrame = PrivateWindowServer.frame(of: anchorWindowID)
        let liveWindowIDs = Set(PrivateWindowServer.menuBarWindowIDs())
        let visiblePersistedItems = model.barrItems.filter { item in
            item.isMovableByBarr &&
                liveWindowIDs.contains(item.windowID) &&
                anchorFrame.map { anchor in item.frame.midX >= anchor.midX } == true
        }
        guard !visiblePersistedItems.isEmpty else { return }

        persistedItemReconciliationInProgress = true
        reconcile(
            visiblePersistedItems,
            beside: anchorWindowID
        ) { [weak self] movedAnyItem in
            guard let self else { return }
            self.persistedItemReconciliationInProgress = false
            if movedAnyItem {
                self.model.refresh()
            }
        }
    }

    private func reconcile(
        _ persistedItems: [MenuBarItem],
        beside anchorWindowID: CGWindowID,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var movedAnyItem = false
            for persistedItem in persistedItems {
                for attempt in 0..<2 {
                    let scannedItems = MenuBarScanner.scan(captureImages: false)
                    guard let currentItem = scannedItems.first(where: {
                        $0.storageKey == persistedItem.storageKey
                    }) else {
                        break
                    }

                    let liveWindowIDs = Set(PrivateWindowServer.menuBarWindowIDs())
                    guard
                        liveWindowIDs.contains(currentItem.windowID),
                        let anchorFrame = PrivateWindowServer.frame(of: anchorWindowID),
                        currentItem.frame.midX >= anchorFrame.midX
                    else {
                        break
                    }

                    let targetPoint = CGPoint(
                        x: anchorFrame.minX - 1,
                        y: anchorFrame.midY
                    )
                    guard MenuBarMover.move(
                        windowID: currentItem.windowID,
                        sourcePID: currentItem.ownerPID,
                        beside: anchorWindowID,
                        at: targetPoint
                    ) else {
                        continue
                    }

                    Thread.sleep(forTimeInterval: attempt == 0 ? 0.14 : 0.22)
                    let refreshedItem = MenuBarScanner.scan(captureImages: false).first {
                        $0.storageKey == persistedItem.storageKey
                    }
                    let refreshedLiveIDs = Set(PrivateWindowServer.menuBarWindowIDs())
                    let refreshedAnchorFrame =
                        PrivateWindowServer.frame(of: anchorWindowID) ?? anchorFrame
                    let isParked = refreshedItem.map {
                        !refreshedLiveIDs.contains($0.windowID) ||
                            $0.frame.midX < refreshedAnchorFrame.midX
                    } ?? !refreshedLiveIDs.contains(currentItem.windowID)
                    if isParked {
                        movedAnyItem = true
                        break
                    }
                }
            }

            DispatchQueue.main.async {
                completion(movedAnyItem)
            }
        }
    }

    private func requestStartupShelf() {
        startupShelfRequested = true
        presentStartupShelfIfReady()
    }

    private func presentStartupShelfIfReady() {
        guard
            startupShelfRequested,
            handledInitialRefresh,
            startupReconciliationComplete || !PermissionCenter.isAccessibilityGranted
        else { return }
        startupShelfRequested = false
        showShelf()
    }

    private func activateFromShelf(_ item: MenuBarItem) {
        guard
            let controlWindowID = windowID(for: statusItem),
            let controlFrame = PrivateWindowServer.frame(of: controlWindowID)
        else {
            model.activationFailed = !MenuBarActivator.activate(item)
            return
        }

        returnHiddenItemNow()
        closeShelf()
        let revealPoint = CGPoint(x: controlFrame.minX - 1, y: controlFrame.midY)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentItem = MenuBarScanner.scan(captureImages: false).first {
                $0.storageKey == item.storageKey
            } ?? item
            let moved = MenuBarMover.move(
                windowID: currentItem.windowID,
                sourcePID: currentItem.ownerPID,
                beside: controlWindowID,
                at: revealPoint
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard let self else { return }
                let revealedItem = MenuBarScanner.scan(captureImages: false).first {
                    $0.storageKey == item.storageKey
                } ?? currentItem
                let activated = moved && MenuBarActivator.activate(revealedItem)
#if DEBUG
                barrActivationLogger.notice(
                    """
                    Activation target=\(item.storageKey, privacy: .public) \
                    moved=\(moved) activated=\(activated) \
                    revealedWindow=\(revealedItem.windowID)
                    """
                )
#endif
                self.model.activationFailed = !activated
                guard moved else {
                    self.showShelf()
                    return
                }
                if activated {
                    self.armReturn(item: item)
                } else {
                    self.parkItem(item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showShelf()
                    }
                }
            }
        }
    }

    private func armReturn(item: MenuBarItem) {
        pendingReturn = { [weak self] in self?.parkItem(item) }

        returnMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.returnHiddenItemNow()
            }
        }

        let fallback = DispatchWorkItem { [weak self] in self?.returnHiddenItemNow() }
        returnFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: fallback)
    }

    private func parkItem(_ originalItem: MenuBarItem, attempt: Int = 0) {
        guard
            let anchorWindowID = windowID(for: storageAnchor),
            let anchorFrame = PrivateWindowServer.frame(of: anchorWindowID)
        else {
            retryParking(originalItem, attempt: attempt)
            return
        }

        let targetPoint = CGPoint(x: anchorFrame.minX - 1, y: anchorFrame.midY)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentItem = MenuBarScanner.scan(captureImages: false).first {
                $0.storageKey == originalItem.storageKey
            } ?? originalItem
            let attempted = MenuBarMover.move(
                windowID: currentItem.windowID,
                sourcePID: currentItem.ownerPID,
                beside: anchorWindowID,
                at: targetPoint
            )
            Thread.sleep(forTimeInterval: 0.12)
            let parked = attempted && MenuBarScanner.scan(captureImages: false).first {
                $0.storageKey == originalItem.storageKey
            }.map { $0.frame.midX < anchorFrame.midX } == true

            DispatchQueue.main.async {
                guard let self else { return }
                if parked {
                    self.updateStorageState()
                    self.model.refresh()
                } else {
                    self.retryParking(originalItem, attempt: attempt)
                }
            }
        }
    }

    private func retryParking(_ item: MenuBarItem, attempt: Int) {
        guard attempt < 2 else {
            model.refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.parkItem(item, attempt: attempt + 1)
        }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.refreshScannerExclusions()
            guard let (anchorWindowID, anchorFrame) = self.membershipAnchor(
                for: item,
                moveToBarr: moveToBarr
            ) else {
#if DEBUG
                barrMembershipLogger.notice(
                    "Move has no anchor target=\(item.storageKey, privacy: .public)"
                )
#endif
                completion(false)
                self.updateStorageState()
                return
            }

#if DEBUG
            barrMembershipLogger.notice(
                """
                Move start direction=\(moveToBarr ? "into-barr" : "to-menu-bar", privacy: .public) \
                target=\(item.storageKey, privacy: .public) window=\(item.windowID) \
                anchor=\(anchorWindowID) frame=\(NSStringFromRect(anchorFrame), privacy: .public)
                """
            )
#endif
            let targetPoint = CGPoint(x: anchorFrame.minX - 1, y: anchorFrame.midY)
            DispatchQueue.global(qos: .userInitiated).async {
                let baselineItems = MenuBarScanner.scan(captureImages: false)
                let baselineSystemKeys = Set(
                    baselineItems
                        .filter { $0.isSystemItem && $0.storageKey != item.storageKey }
                        .map(\.storageKey)
                )
                var moved = false
                var lastScan = baselineItems
                for attempt in 0..<2 where !moved {
                    let currentItem = lastScan.first {
                        $0.storageKey == item.storageKey
                    } ?? (attempt == 0 ? item : nil)
                    guard let currentItem else { break }

#if DEBUG
                    barrMembershipLogger.notice(
                        """
                        Move attempt=\(attempt) target=\(currentItem.storageKey, privacy: .public) \
                        window=\(currentItem.windowID) sourceFrame=\(NSStringFromRect(currentItem.frame), privacy: .public) \
                        targetPoint=\(NSStringFromPoint(targetPoint), privacy: .public)
                        """
                    )
#endif
                    let attempted = MenuBarMover.move(
                        windowID: currentItem.windowID,
                        sourcePID: currentItem.ownerPID,
                        beside: anchorWindowID,
                        at: targetPoint
                    )
                    guard attempted else { continue }

                    var targetWasObserved = false
                    for delay in [0.08, 0.14, 0.22] where !moved {
                        Thread.sleep(forTimeInterval: delay)
                        lastScan = MenuBarScanner.scan(captureImages: false)
                        let liveMenuBarWindowIDs = Set(PrivateWindowServer.menuBarWindowIDs())
                        let verificationAnchorFrame =
                            PrivateWindowServer.frame(of: anchorWindowID) ?? anchorFrame
                        let movedItem = lastScan.first {
                            $0.storageKey == item.storageKey
                        }
#if DEBUG
                        barrMembershipLogger.notice(
                            """
                            Move poll delay=\(delay) targetSeen=\(movedItem != nil) \
                            observedWindow=\(movedItem?.windowID ?? 0) \
                            observedFrame=\(movedItem.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public) \
                            observedLive=\(movedItem.map { liveMenuBarWindowIDs.contains($0.windowID) } ?? false) \
                            sourceLive=\(liveMenuBarWindowIDs.contains(currentItem.windowID)) \
                            liveAnchorFrame=\(NSStringFromRect(verificationAnchorFrame), privacy: .public)
                            """
                        )
#endif
                        targetWasObserved = targetWasObserved || movedItem != nil
                        moved = moveToBarr
                            ? movedItem.map {
                                !liveMenuBarWindowIDs.contains($0.windowID) ||
                                    $0.frame.midX < verificationAnchorFrame.midX
                            } ?? !liveMenuBarWindowIDs.contains(currentItem.windowID)
                            : movedItem.map {
                                liveMenuBarWindowIDs.contains($0.windowID)
                            } == true
                    }

                    // If the scanner lost the target entirely, another drag
                    // could act on a stale/reused window ID and disturb a
                    // neighboring system item. Let a later refresh reconcile it.
                    if !targetWasObserved && !moved {
                        break
                    }
                }

#if DEBUG
                barrMembershipLogger.notice(
                    """
                    Move result target=\(item.storageKey, privacy: .public) \
                    success=\(moved) observedItems=\(lastScan.count)
                    """
                )
                if moved && !baselineSystemKeys.isEmpty {
                    let presentKeys = Set(
                        MenuBarScanner.scan(captureImages: false).map(\.storageKey)
                    )
                    let missingKeys = baselineSystemKeys.subtracting(presentKeys)
                    if !missingKeys.isEmpty {
                        print("[Barr] System items missing after move: \(missingKeys.sorted())")
                    }
                }
#endif

                DispatchQueue.main.async {
                    completion(moved)
                    self.model.refresh()
                }
            }
        }
    }

    private func updateStorageState() {
        guard storageAnchor != nil else { return }
        storageUpdateGeneration += 1
        let generation = storageUpdateGeneration
        let keepShelfOpen = shelfPanel?.isVisible == true

        // Do not expand the anchor for an optimistic move. If Barr only
        // remembers items whose apps are no longer running, barrItems contains
        // the pending item before it has physically moved. Expanding here can
        // make the anchor unresolvable and cause that first move to fail.
        guard model.hasVisiblePersistedBarrItems else {
            storageAnchor.length = collapsedStorageLength
            refreshScannerExclusions()
            repositionShelfIfNeeded(keepOpen: keepShelfOpen)
            return
        }

        // The anchor's right edge stays fixed as its width changes. Extending it
        // from that edge to just beyond the screen's left edge parks every item
        // on its left without measuring, collapsing, or reshuffling the lane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard
                let self,
                let windowID = self.windowID(for: self.storageAnchor),
                let anchorFrame = PrivateWindowServer.frame(of: windowID),
                let screen = self.storageAnchor.button?.window?.screen ?? NSScreen.main
            else { return }

            guard generation == self.storageUpdateGeneration else { return }
            let desiredLength = min(
                max(self.collapsedStorageLength, anchorFrame.maxX - screen.frame.minX + 8),
                screen.frame.width + 8
            )
            if abs(self.storageAnchor.length - desiredLength) > 1 {
                self.storageAnchor.length = desiredLength
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.refreshScannerExclusions()
                self.repositionShelfIfNeeded(keepOpen: keepShelfOpen)
            }
        }
    }

    private func repositionShelfIfNeeded(keepOpen: Bool) {
        guard keepOpen, let button = statusItem.button else { return }
        shelfPanel.show(relativeTo: button)
    }

    private func configureStatusItems() {
        // AppKit updates this preference whenever neighboring status items are
        // reordered. That can strand Barr beneath the notch on the next launch,
        // leaving its panel visible with no reachable control. Barr is the
        // gateway to every parked item, so restore it to the highest visible
        // status-item priority every time the process starts.
        setPreferredPosition(0, autosaveName: "BarrControl", force: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "BarrControl"
#if DEBUG
        statusItem.button?.image = NSImage(
            systemSymbolName: "ladybug.fill",
            accessibilityDescription: "Barr debug build"
        )
        statusItem.button?.title = " DEBUG"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .systemFont(ofSize: 10, weight: .bold)
        statusItem.button?.toolTip = "Barr — Debug Build"
#else
        statusItem.button?.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: "Barr overflow shelf"
        )
        statusItem.button?.toolTip = "Barr"
#endif
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemPressed(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])

        // A far-left parking boundary. It remains zero-width until at least one
        // explicitly selected item has been moved to its left.
        setPreferredPosition(1_000_000_000, autosaveName: "BarrStorageAnchor", force: true)
        storageAnchor = NSStatusBar.system.statusItem(withLength: collapsedStorageLength)
        storageAnchor.autosaveName = "BarrStorageAnchor"
        if let storageButton = storageAnchor.button {
            storageButton.image = nil
            storageButton.title = ""
            storageButton.toolTip = nil
            storageButton.isEnabled = false
            storageButton.alphaValue = 0
            storageButton.setAccessibilityElement(false)
        }
    }

    private func membershipAnchor(
        for item: MenuBarItem,
        moveToBarr: Bool
    ) -> (CGWindowID, CGRect)? {
        if moveToBarr {
            guard
                let windowID = windowID(for: storageAnchor),
                let frame = PrivateWindowServer.frame(of: windowID)
            else { return nil }
            return (windowID, frame)
        }

        if
            let neighbor = model.returnAnchor(for: item),
            PrivateWindowServer.menuBarWindowIDs().contains(neighbor.windowID),
            let frame = PrivateWindowServer.frame(of: neighbor.windowID)
        {
            return (neighbor.windowID, frame)
        }

        if
            let windowID = windowID(for: statusItem),
            let frame = PrivateWindowServer.frame(of: windowID)
        {
            return (windowID, frame)
        }

        guard
            let windowID = windowID(for: storageAnchor),
            let frame = PrivateWindowServer.frame(of: windowID)
        else { return nil }
        return (windowID, frame)
    }

    private func refreshScannerExclusions() {
        let windowIDs = [windowID(for: statusItem), windowID(for: storageAnchor)]
            .compactMap { $0 }
        MenuBarScanner.setExcludedWindowIDs(Set(windowIDs))
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
        let maximumScore = max(100, buttonFrame.width * 0.2)
        return PrivateWindowServer.menuBarWindowIDs()
            .compactMap { windowID -> (CGWindowID, CGFloat)? in
                guard
                    let frame = PrivateWindowServer.frame(of: windowID),
                    frame.width > 0,
                    abs(frame.height - buttonFrame.height) < 20
                else {
                    return nil
                }
                let score = abs(frame.midX - buttonFrame.midX) + abs(frame.width - buttonFrame.width) * 2
                return (windowID, score)
            }
            .filter { $0.1 < maximumScore }
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
        shelfPanel.isVisible ? closeShelf() : showShelf()
    }

    private func showShelf(attempt: Int = 0) {
        guard let button = statusItem.button, button.window != nil else {
            retryShowingShelf(after: attempt)
            return
        }
        refreshScannerExclusions()
        model.refreshLoginItemStatus()
        model.refresh()
        if shelfPanel.show(relativeTo: button) {
            installShelfDismissMonitors()
        } else {
            removeShelfDismissMonitors()
            retryShowingShelf(after: attempt)
        }
    }

    private func retryShowingShelf(after attempt: Int) {
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showShelf(attempt: attempt + 1)
        }
    }

    private func closeShelf() {
        shelfPanel?.close()
        removeShelfDismissMonitors()
    }

    private func installShelfDismissMonitors() {
        removeShelfDismissMonitors()
        shelfGlobalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeShelf()
            }
        }
        shelfLocalDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeShelf()
            } else if
                event.type != .keyDown,
                event.window !== self.shelfPanel,
                event.window !== self.statusItem.button?.window
            {
                self.closeShelf()
            }
            return event
        }
    }

    private func removeShelfDismissMonitors() {
        if let shelfGlobalDismissMonitor {
            NSEvent.removeMonitor(shelfGlobalDismissMonitor)
            self.shelfGlobalDismissMonitor = nil
        }
        if let shelfLocalDismissMonitor {
            NSEvent.removeMonitor(shelfLocalDismissMonitor)
            self.shelfLocalDismissMonitor = nil
        }
    }

    private func showContextMenu() {
        model.refreshLoginItemStatus()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh icons", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let openAtLoginItem = menu.addItem(
            withTitle: "Open at Login",
            action: #selector(toggleOpenAtLogin),
            keyEquivalent: ""
        )
        openAtLoginItem.target = self
        openAtLoginItem.state = model.opensAtLogin ? .on : .off
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
        closeShelf()
        refreshScannerExclusions()
        model.refresh()
    }

    @objc private func runningApplicationsChanged() {
        runningApplicationsGeneration += 1
        let generation = runningApplicationsGeneration
        for delay in [0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard
                    let self,
                    generation == self.runningApplicationsGeneration
                else { return }
                self.refreshScannerExclusions()
                self.model.refresh()
            }
        }
    }

    @objc private func refresh() {
        model.refresh()
    }

    @objc private func toggleOpenAtLogin() {
        model.setOpensAtLogin(!model.opensAtLogin)
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
