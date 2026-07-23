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

    init() {
        movedItemKeys = Set(UserDefaults.standard.stringArray(forKey: "BarrMovedItemKeys") ?? [])
        permissionPoller = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updatePermissionState()
            }
    }

    var barrItems: [MenuBarItem] {
        items.filter { movedItemKeys.contains($0.storageKey) }
    }

    var menuBarItems: [MenuBarItem] {
        items.filter { !movedItemKeys.contains($0.storageKey) }
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
                self.items = found
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

    private func changeMembership(of item: MenuBarItem, moveToBarr: Bool) {
        guard !movingItemKeys.contains(item.storageKey) else { return }
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
