import AppKit
import Combine

@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var movedItemKeys: Set<String>
    @Published private(set) var movingItemKeys: Set<String> = []
    @Published var isManaging = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var canCaptureScreen = PermissionCenter.canCaptureScreen
    @Published private(set) var canUseAccessibility = PermissionCenter.isAccessibilityGranted
    @Published private(set) var screenCaptureNeedsRestart = false
    @Published var activationFailed = false

    var onItemsChanged: (() -> Void)?
    var onActivate: ((MenuBarItem) -> Void)?
    var onRestart: (() -> Void)?
    var onMembershipChange: ((MenuBarItem, Bool, @escaping (Bool) -> Void) -> Void)?
    private var refreshGeneration = 0
    private var permissionPoller: AnyCancellable?
    private var requestedScreenCaptureThisLaunch = false
    private var itemOrder: [String]

    init() {
        movedItemKeys = Set(UserDefaults.standard.stringArray(forKey: "BarrMovedItemKeys") ?? [])
        itemOrder = UserDefaults.standard.stringArray(forKey: "BarrItemOrder") ?? []
        permissionPoller = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updatePermissionState()
            }
    }

    var barrItems: [MenuBarItem] {
        ordered(items.filter { movedItemKeys.contains($0.storageKey) })
    }

    var menuBarItems: [MenuBarItem] {
        ordered(items.filter { !movedItemKeys.contains($0.storageKey) })
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        canCaptureScreen = PermissionCenter.canCaptureScreen
        canUseAccessibility = PermissionCenter.isAccessibilityGranted
        screenCaptureNeedsRestart = requestedScreenCaptureThisLaunch && !canCaptureScreen

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MenuBarScanner.scan()
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                self.migrateLegacyKeys(using: found)
                self.items = found
                self.mergeItemOrder(found)
                self.canCaptureScreen = PermissionCenter.canCaptureScreen || found.contains { $0.image != nil }
                self.canUseAccessibility = PermissionCenter.isAccessibilityGranted
                self.screenCaptureNeedsRestart = self.requestedScreenCaptureThisLaunch && !self.canCaptureScreen
                self.isRefreshing = false
                self.onItemsChanged?()
#if DEBUG
                print("[Barr] Found \(found.count) menu bar app item(s)")
#endif
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
        changeMembership(of: item, moveToBarr: true)
    }

    func returnToMenuBar(_ item: MenuBarItem) {
        changeMembership(of: item, moveToBarr: false)
    }

    func setManaging(_ managing: Bool) {
        isManaging = managing
        onItemsChanged?()
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
        guard movingItemKeys.isEmpty else { return }
        movingItemKeys.insert(item.storageKey)

        onMembershipChange?(item, moveToBarr) { [weak self] success in
            guard let self else { return }
            self.movingItemKeys.remove(item.storageKey)
            if success {
                if moveToBarr {
                    self.movedItemKeys.insert(item.storageKey)
                } else {
                    self.movedItemKeys.remove(item.storageKey)
                }
                UserDefaults.standard.set(self.movedItemKeys.sorted(), forKey: "BarrMovedItemKeys")
            }
            self.onItemsChanged?()
        }
    }

    private func ordered(_ source: [MenuBarItem]) -> [MenuBarItem] {
        let indexes = itemOrder.enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element] == nil { result[entry.element] = entry.offset }
        }
        return source.sorted {
            let lhs = indexes[$0.storageKey] ?? Int.max
            let rhs = indexes[$1.storageKey] ?? Int.max
            if lhs == rhs { return $0.frame.minX < $1.frame.minX }
            return lhs < rhs
        }
    }

    private func mergeItemOrder(_ found: [MenuBarItem]) {
        var known = Set(itemOrder)
        var changed = false
        for item in found where known.insert(item.storageKey).inserted {
            itemOrder.append(item.storageKey)
            changed = true
        }
        if changed {
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
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.updatePermissionState()
            }
        }
    }

    private func updatePermissionState() {
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
        onItemsChanged?()

        if becameReady {
            refresh()
        }
    }
}
