import AppKit
import ServiceManagement

@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var movedItemKeys: Set<String>
    @Published private var pendingMembershipChange: PendingMembershipChange?
    @Published var isManaging = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var canCaptureScreen = PermissionCenter.canCaptureScreen
    @Published private(set) var canUseAccessibility = PermissionCenter.isAccessibilityGranted
    @Published private(set) var screenCaptureNeedsRestart = false
    @Published var activationFailed = false
    @Published private(set) var showsSystemItems: Bool
    @Published private(set) var opensAtLogin: Bool
    @Published private(set) var loginItemRequiresApproval: Bool
    @Published private(set) var loginItemError: String?

    var onItemsChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    var onRefreshCompleted: (() -> Void)?
    var onActivate: ((MenuBarItem) -> Void)?
    var onRestart: (() -> Void)?
    var onMembershipChange: ((MenuBarItem, Bool, @escaping (Bool) -> Void) -> Void)?
    private var refreshInProgress = false
    private var refreshRequested = false
    private var refreshRequestedCaptureImages = false
    private var permissionCheckGeneration = 0
    private var requestedScreenCaptureThisLaunch = false
    private var itemOrder: [String]
    private var itemOrderIndexes: [String: Int]

    private struct PendingMembershipChange {
        let itemKey: String
        let moveToBarr: Bool
    }

    init() {
        let loginItemStatus = SMAppService.mainApp.status
        let storedItemOrder = UserDefaults.standard.stringArray(forKey: "BarrItemOrder") ?? []
        movedItemKeys = Set(UserDefaults.standard.stringArray(forKey: "BarrMovedItemKeys") ?? [])
        itemOrder = storedItemOrder
        itemOrderIndexes = Self.orderIndexes(for: storedItemOrder)
        showsSystemItems = UserDefaults.standard.bool(forKey: "BarrShowsSystemItems")
        opensAtLogin = Self.isLoginItemRequested(loginItemStatus)
        loginItemRequiresApproval = loginItemStatus == .requiresApproval
        loginItemError = nil
    }

    var barrItems: [MenuBarItem] {
        ordered(items.filter { isInBarr($0.storageKey) })
    }

    var hasVisiblePersistedBarrItems: Bool {
        items.contains { movedItemKeys.contains($0.storageKey) }
    }

    var menuBarItems: [MenuBarItem] {
        ordered(
            items.filter {
                !isInBarr($0.storageKey) && (showsSystemItems || !$0.isSystemItem)
            }
        )
    }

    var movingItemKeys: Set<String> {
        pendingMembershipChange.map { [$0.itemKey] } ?? []
    }

    func containsItem(ownedBy processIdentifier: pid_t) -> Bool {
        items.contains { $0.ownerPID == processIdentifier }
    }

    func refresh(captureImages: Bool = true) {
        guard !refreshInProgress else {
            refreshRequested = true
            refreshRequestedCaptureImages =
                refreshRequestedCaptureImages || captureImages
            return
        }
        beginRefresh(captureImages: captureImages)
    }

    private func beginRefresh(captureImages: Bool) {
        refreshInProgress = true
        if !isRefreshing {
            isRefreshing = true
        }
        updatePermissionState(refreshWhenReady: false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MenuBarScanner.scan(captureImages: captureImages)
            DispatchQueue.main.async {
                guard let self else { return }
                self.migrateLegacyKeys(using: found)
                let existingItems = Dictionary(
                    self.items.map { ($0.storageKey, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let stableItems = found.map { item in
                    guard item.image == nil, let previousImage = existingItems[item.storageKey]?.image else {
                        return item
                    }
                    return item.replacingImage(previousImage)
                }
                let itemsChanged = !self.items.elementsEqual(
                    stableItems,
                    by: { $0.hasSameContent(as: $1) }
                )
                if itemsChanged {
                    self.items = stableItems
                }
                self.mergeItemOrder(stableItems)
                self.updatePermissionState(refreshWhenReady: false)
                if itemsChanged {
                    self.onItemsChanged?()
                }
                self.onRefreshCompleted?()
#if DEBUG
                print("[Barr] Found \(found.count) menu bar app item(s)")
#endif

                if self.refreshRequested {
                    let nextRefreshCapturesImages = self.refreshRequestedCaptureImages
                    self.refreshRequested = false
                    self.refreshRequestedCaptureImages = false
                    self.beginRefresh(captureImages: nextRefreshCapturesImages)
                } else {
                    self.refreshInProgress = false
                    self.isRefreshing = false
                }
            }
        }
    }

    func activate(_ item: MenuBarItem) {
        guard PermissionCenter.isAccessibilityGranted else {
            PermissionCenter.requestAccessibility()
            return
        }
        activationFailed = false
        onActivate?(item)
    }

    func moveToBarr(_ item: MenuBarItem) {
        guard item.isMovableByBarr else { return }
        changeMembership(of: item, moveToBarr: true)
    }

    func returnToMenuBar(_ item: MenuBarItem) {
        changeMembership(of: item, moveToBarr: false)
    }

    func setManaging(_ managing: Bool) {
        guard isManaging != managing else { return }
        isManaging = managing
        onLayoutChanged?()
    }

    func setShowsSystemItems(_ showsSystemItems: Bool) {
        guard self.showsSystemItems != showsSystemItems else { return }
        self.showsSystemItems = showsSystemItems
        UserDefaults.standard.set(showsSystemItems, forKey: "BarrShowsSystemItems")
    }

    func setOpensAtLogin(_ opensAtLogin: Bool) {
        let service = SMAppService.mainApp
        loginItemError = nil

        do {
            if opensAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }

        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        let shouldOpenAtLogin = Self.isLoginItemRequested(status)
        let requiresApproval = status == .requiresApproval
        if opensAtLogin != shouldOpenAtLogin {
            opensAtLogin = shouldOpenAtLogin
        }
        if loginItemRequiresApproval != requiresApproval {
            loginItemRequiresApproval = requiresApproval
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func isLoginItemRequested(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    func returnAnchor(for item: MenuBarItem) -> MenuBarItem? {
        guard let itemIndex = itemOrder.firstIndex(of: item.storageKey) else { return nil }
        let currentByKey = items.reduce(into: [String: MenuBarItem]()) { result, current in
            result[current.storageKey] = current
        }
        // Command-dragging beside a status item inserts after that item on
        // current macOS releases, so anchor to the closest visible predecessor.
        return itemOrder.prefix(itemIndex).reversed().lazy
            .filter { !self.movedItemKeys.contains($0) }
            .compactMap { currentByKey[$0] }
            .first
    }

    private func changeMembership(of item: MenuBarItem, moveToBarr: Bool) {
        guard pendingMembershipChange == nil, let onMembershipChange else { return }
        pendingMembershipChange = PendingMembershipChange(
            itemKey: item.storageKey,
            moveToBarr: moveToBarr
        )
        onItemsChanged?()

        onMembershipChange(item, moveToBarr) { [weak self] success in
            guard let self else { return }
            if success {
                if moveToBarr {
                    self.movedItemKeys.insert(item.storageKey)
                } else {
                    self.movedItemKeys.remove(item.storageKey)
                }
                UserDefaults.standard.set(self.movedItemKeys.sorted(), forKey: "BarrMovedItemKeys")
            }
            self.pendingMembershipChange = nil
            self.onItemsChanged?()
        }
    }

    private func isInBarr(_ itemKey: String) -> Bool {
        if pendingMembershipChange?.itemKey == itemKey {
            return pendingMembershipChange?.moveToBarr == true
        }
        return movedItemKeys.contains(itemKey)
    }

    private func ordered(_ source: [MenuBarItem]) -> [MenuBarItem] {
        return source.sorted {
            let lhs = itemOrderIndexes[$0.storageKey] ?? Int.max
            let rhs = itemOrderIndexes[$1.storageKey] ?? Int.max
            if lhs == rhs { return $0.frame.minX < $1.frame.minX }
            return lhs < rhs
        }
    }

    private static func orderIndexes(for order: [String]) -> [String: Int] {
        order.enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element] == nil {
                result[entry.element] = entry.offset
            }
        }
    }

    private func mergeItemOrder(_ found: [MenuBarItem]) {
        var known = Set(itemOrder)
        var changed = false
        let foundKeys = found.reduce(into: [String]()) { result, item in
            if !result.contains(item.storageKey) {
                result.append(item.storageKey)
            }
        }

        for (foundIndex, key) in foundKeys.enumerated() where known.insert(key).inserted {
            let precedingKey = foundKeys[..<foundIndex].reversed().first {
                itemOrder.contains($0)
            }
            let followingKey = foundKeys[(foundIndex + 1)...].first {
                itemOrder.contains($0)
            }

            if let precedingKey, let orderIndex = itemOrder.firstIndex(of: precedingKey) {
                itemOrder.insert(key, at: orderIndex + 1)
            } else if let followingKey, let orderIndex = itemOrder.firstIndex(of: followingKey) {
                itemOrder.insert(key, at: orderIndex)
            } else {
                itemOrder.append(key)
            }
            changed = true
        }
        if changed {
            itemOrderIndexes = Self.orderIndexes(for: itemOrder)
            UserDefaults.standard.set(itemOrder, forKey: "BarrItemOrder")
        }
    }

    private func migrateLegacyKeys(using found: [MenuBarItem]) {
        var movedChanged = false
        var orderChanged = false

        for item in found where item.storageKey != item.legacyStorageKey {
            if movedItemKeys.remove(item.legacyStorageKey) != nil {
                movedItemKeys.insert(item.storageKey)
                movedChanged = true
            }
            for index in itemOrder.indices where itemOrder[index] == item.legacyStorageKey {
                itemOrder[index] = item.storageKey
                orderChanged = true
            }
        }

        if orderChanged {
            var seen = Set<String>()
            itemOrder = itemOrder.filter { seen.insert($0).inserted }
            itemOrderIndexes = Self.orderIndexes(for: itemOrder)
            UserDefaults.standard.set(itemOrder, forKey: "BarrItemOrder")
        }
        if movedChanged {
            UserDefaults.standard.set(movedItemKeys.sorted(), forKey: "BarrMovedItemKeys")
        }
    }

    func requestScreenCapture() {
        PermissionCenter.requestScreenCapture { [weak self] _ in
            guard let self else { return }
            // macOS may return false until the process relaunches even after the
            // user has enabled Barr in Screen Recording settings.
            self.requestedScreenCaptureThisLaunch = true
            self.updatePermissionState()
            self.schedulePermissionChecks()
        }
    }

    func requestAccessibility() {
        PermissionCenter.requestAccessibility()
        schedulePermissionChecks()
    }

    func restartBarr() {
        onRestart?()
    }

    private func schedulePermissionChecks() {
        guard !canCaptureScreen || !canUseAccessibility else { return }
        permissionCheckGeneration += 1
        let generation = permissionCheckGeneration
        for delay in [0.5, 1.5, 3.0, 6.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard
                    let self,
                    generation == self.permissionCheckGeneration
                else { return }
                self.updatePermissionState()
            }
        }
    }

    private func updatePermissionState(refreshWhenReady: Bool = true) {
        let capture = PermissionCenter.canCaptureScreen
        let accessibility = PermissionCenter.isAccessibilityGranted
        let needsRestart = requestedScreenCaptureThisLaunch && !capture
        guard
            capture != canCaptureScreen ||
            accessibility != canUseAccessibility ||
            needsRestart != screenCaptureNeedsRestart
        else { return }

        let becameReady = capture && accessibility && (!canCaptureScreen || !canUseAccessibility)
        canCaptureScreen = capture
        canUseAccessibility = accessibility
        screenCaptureNeedsRestart = needsRestart
        onLayoutChanged?()

        if capture && accessibility {
            permissionCheckGeneration += 1
        }
        if becameReady && refreshWhenReady {
            refresh()
        }
    }
}
