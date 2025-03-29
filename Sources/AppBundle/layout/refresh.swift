import AppKit
import Common

/// It's one of the most important function of the whole application.
/// The function is called as a feedback response on every user input.
/// The function is idempotent.
@MainActor
func refreshSession<T>(
    _ event: RefreshSessionEvent,
    screenIsDefinitelyUnlocked: Bool,
    startup: Bool = false,
    body: @MainActor () async throws(CancellationError) -> T
) async throws(CancellationError) -> T {
    // refreshSessionEventForDebug = event
    // defer { refreshSessionEventForDebug = nil }
    if screenIsDefinitelyUnlocked { resetClosedWindowsCache() }
    gc()
    gcMonitors()

    detectNewAppsAndWindows(startup: startup)

    let nativeFocused = getNativeFocusedWindow(startup: startup)
    if let nativeFocused { debugWindowsIfRecording(nativeFocused) }
    updateFocusCache(nativeFocused)
    let focusBefore = focus.windowOrNil

    try await refreshModel()
    let result = try await body()
    try await refreshModel()

    let focusAfter = focus.windowOrNil

    if startup {
        smartLayoutAtStartup()
    }

    if TrayMenuModel.shared.isEnabled {
        if focusBefore != focusAfter {
            focusAfter?.nativeFocusAsync() // syncFocusToMacOs
        }

        updateTrayText()
        normalizeLayoutReason(startup: startup)
        try await layoutWorkspaces()
    }
    return result
}

@MainActor
func refreshAndLayout(_ event: RefreshSessionEvent, screenIsDefinitelyUnlocked: Bool, startup: Bool = false) async throws(CancellationError) {
    try await refreshSession(event, screenIsDefinitelyUnlocked: screenIsDefinitelyUnlocked, startup: startup, body: {})
}

@MainActor
func refreshModel() async throws(CancellationError) {
    gc()
    try await checkOnFocusChangedCallbacks()
    normalizeContainers()
}

@MainActor
private func gc() {
    // Garbage collect terminated apps and windows before working with all windows
    MacApp.garbageCollectTerminatedApps()
    gcWindows()
    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func foo() async -> Bool {
    return true
}

func bar() async {
    // let f = Task { await foo() }
    async let f = foo()
    print(await f)
}

@MainActor
func gcWindows() {
    // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
    // Second and third lines of defence are technically needed only to avoid potential flickering
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
    let toKill = MacWindow.allWindowsMap.filter { $0.value.axWindow.containingWindowId(signpostEvent: $0.value.app.name) == nil }
    // If all windows are "unobservable", it's highly propable that loginwindow might be still active and we are still
    // recovering from unlock
    if toKill.count == MacWindow.allWindowsMap.count { return }
    for window in toKill {
        window.value.garbageCollect(skipClosedWindowsCache: false)
    }
}

func refreshObs(_ obs: AXObserver, ax: AXUIElement, notif: CFString, data: UnsafeMutableRawPointer?) {
    check(Thread.isMainThread)
    let notif = notif as String
    Task {
        try await refreshAndLayout(.ax(notif), screenIsDefinitelyUnlocked: false)
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws(CancellationError) {
    let monitors = monitors
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        let corner: OptimalHideCorner =
            monitors.contains(where: { m in m.rect.contains(brc1) || m.rect.contains(brc2) || m.rect.contains(brc3) }) &&
            monitors.allSatisfy { m in !m.rect.contains(blc1) && !m.rect.contains(blc2) && !m.rect.contains(blc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        for window in workspace.allLeafWindowsRecursive {
            try await (window as! MacWindow).hideInCorner(corner) // todo as!
        }
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}

@MainActor
private func detectNewAppsAndWindows(startup: Bool) {
    for app in apps {
        app.detectNewWindows(startup: startup)
    }
}

@MainActor
private func smartLayoutAtStartup() {
    let workspace = focus.workspace
    let root = workspace.rootTilingContainer
    if root.children.count <= 3 {
        root.layout = .tiles
    } else {
        root.layout = .accordion
    }
}
