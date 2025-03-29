import AppKit
import Common

final class MacWindow: Window {
    let axWindow: AXUIElement
    /*conforms*/ let macApp: MacApp
    let appActor: AppActor
    // todo take into account monitor proportions
    private var prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect: CGPoint?
    private var axObservers: [AxObserverWrapper] = [] // keep observers in memory

    @MainActor
    private init(_ id: CGWindowID, _ app: MacApp, _ actor: AppActor, _ axWindow: AXUIElement, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.axWindow = axWindow
        self.macApp = app
        self.appActor = actor
        super.init(id: id, app, lastFloatingSize: axWindow.get(Ax.sizeAttr), parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [CGWindowID: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    static func get(app: MacApp, axWindow: AXUIElement, startup: Bool) async throws(CancellationError) -> MacWindow? {
        guard let id = axWindow.containingWindowId() else { return nil }
        if let existing = allWindowsMap[id] {
            return existing
        } else {
            // Delay new window detection if mouse is down
            // It helps with apps that allow dragging their tabs out to create new windows
            // https://github.com/nikitabobko/AeroSpace/issues/1001
            if isLeftMouseButtonDown { return nil }

            let data = getBindingDataForNewWindow(
                axWindow,
                startup ? (axWindow.center?.monitorApproximation ?? mainMonitor).activeWorkspace : focus.workspace,
                app
            )
            let window = MacWindow(id, app, errorT("drop MacApp dependency first"), axWindow, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)

            if window.observe(refreshObs, kAXUIElementDestroyedNotification) &&
                window.observe(refreshObs, kAXWindowDeminiaturizedNotification) &&
                window.observe(refreshObs, kAXWindowMiniaturizedNotification) &&
                window.observe(movedObs, kAXMovedNotification) &&
                window.observe(resizedObs, kAXResizedNotification)
            {
                allWindowsMap[id] = window
                debugWindowsIfRecording(window)
                if !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
                    try await tryOnWindowDetected(window, startup: startup)
                }
                return window
            } else {
                window.garbageCollect(skipClosedWindowsCache: true)
                return nil
            }
        }
    }

    var description: String {
        let description = [
            ("title", title),
            ("role", axWindow.get(Ax.roleAttr)),
            ("subrole", axWindow.get(Ax.subroleAttr)),
            ("identifier", axWindow.get(Ax.identifierAttr)),
            ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
            ("windowId", String(windowId)),
        ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
        return "Window(\(description))"
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded(window: self) }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        for obs in axObservers {
            AXObserverRemoveNotification(obs.obs, obs.ax, obs.notif)
        }
        axObservers = []
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .workspace, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocusAsync()
                    }
                case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer:
                    break // Don't switch back on popup destruction
            }
        }
    }

    private func observe(_ handler: AXObserverCallback, _ notifKey: String) -> Bool {
        guard let observer = AXObserver.observe(app.pid, notifKey, axWindow, handler, data: self) else { return false }
        axObservers.append(AxObserverWrapper(obs: observer, ax: axWindow, notif: notifKey as CFString))
        return true
    }

    override var title: String { axWindow.get(Ax.titleAttr) ?? "" }
    override var isMacosFullscreen: Bool { axWindow.get(Ax.isFullscreenAttr) == true }
    override var isMacosMinimized: Bool { axWindow.get(Ax.minimizedAttr) == true }

    override func nativeFocusAsync() {
        appActor.nativeFocusAsync(windowId)
    }

    override func close() -> Bool {
        guard let closeButton = axWindow.get(Ax.closeButtonAttr) else { return false }
        if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) != AXError.success { return false }
        garbageCollect(skipClosedWindowsCache: true)
        return true
    }

    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws(CancellationError) {
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent
        // `hideEmulation` calls
        if !isHiddenInCorner {
            guard let topLeftCorner = try await getTopLeftCorner() else { return }
            guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
            prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect =
                topLeftCorner - nodeWorkspace.workspaceMonitor.rect.topLeftCorner
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = getSize() else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = appActor.isZoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = appActor.isZoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setTopLeftCornerAsync(p)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                setTopLeftCornerAsync(nodeWorkspace.workspaceMonitor.rect.topLeftCorner + prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect != nil
    }

    override func getSize() -> CGSize? {
        axWindow.get(Ax.sizeAttr)
    }

    override func setTopLeftCornerAsync(_ point: CGPoint) {
        appActor.setTopLeftCornerAsync(windowId, point)
    }

    override func setFrameAsync(_ topLeft: CGPoint?, _ size: CGSize?) {
        appActor.setFrameAsync(windowId, topLeft, size)
    }

    override func setAxFrameDuringTermination(_ topLeft: CGPoint?, _ size: CGSize?) async throws(CancellationError) {
        try await appActor.setAxFrameDuringTermination(windowId, topLeft, size)
    }

    override func setSizeAsync(_ size: CGSize) {
        appActor.setSizeAsync(windowId, size)
    }

    override func getTopLeftCorner() async throws(CancellationError) -> CGPoint? {
        try await appActor.getTopLeftCorner(windowId)
    }

    override func getRect() async throws(CancellationError) -> Rect? {
        try await appActor.getRect(windowId)
    }
}


@MainActor func isWindow(_ axWindow: AXUIElement, _ app: MacApp) -> Bool { // todo drop
    return isWindowImpl(axWindow: axWindow, axApp: app.axApp, appBundleId: app.id)
}

/// Alternative name: !isPopup
///
/// Why do we need to filter out non-windows?
/// - "floating by default" workflow
/// - It's annoying that the focus command treats these popups as floating windows
func isWindowImpl(axWindow: AXUIElement, axApp: AXUIElement, appBundleId: String?) -> Bool { // todo cover with tests
    // Just don't do anything with "Ghostty Quick Terminal" windows.
    // Its position and size are managed by the Ghostty itself
    // https://github.com/nikitabobko/AeroSpace/issues/103
    // https://github.com/ghostty-org/ghostty/discussions/3512
    if appBundleId == "com.mitchellh.ghostty" && axWindow.get(Ax.identifierAttr) == "com.mitchellh.ghostty.quickTerminal" {
        return false
    }

    // Try to filter out incredibly weird popup like AXWindows without any buttons.
    // E.g.
    // - Sonoma (macOS 14) keyboard layout switch (AXSubrole == AXDialog)
    // - IntelliJ context menu (right mouse click)
    // - Telegram context menu (right mouse click)
    // - Share window purple "pill" indicator https://github.com/nikitabobko/AeroSpace/issues/1101. Title is not empty
    // - Tooltips on links mouse hover in browsers (Chrome, Firefox)
    // - Tooltips on buttons (e.g. new tab, Extensions) mouse hover in browsers (Chrome, Firefox). Title is not empty
    // Make sure that the following AXWindow remain windows:
    // - macOS native file picker ("Open..." menu) (subrole == kAXDialogSubrole)
    // - telegram image viewer (subrole == kAXFloatingWindowSubrole)
    // - Finder preview (hit space) (subrole == "Quick Look")
    // - Firefox non-native video fullscreen (about:config -> full-screen-api.macos-native-full-screen -> false, subrole == AXUnknown)
    return axWindow.get(Ax.closeButtonAttr) != nil ||
        axWindow.get(Ax.fullscreenButtonAttr) != nil ||
        axWindow.get(Ax.zoomButtonAttr) != nil ||
        axWindow.get(Ax.minimizeButtonAttr) != nil ||

        axWindow.get(Ax.isFocused) == true ||  // 3 different ways to detect if the window is focused
        axWindow.get(Ax.isMainAttr) == true ||
        axApp.get(Ax.focusedWindowAttr)?.containingWindowId() == axWindow.containingWindowId() ||

        axWindow.get(Ax.subroleAttr) == kAXStandardWindowSubrole
}

// This function is referenced in the guide
func isDialogHeuristic(_ axWindow: AXUIElement, _ app: MacApp) -> Bool {
    // Note: a lot of windows don't have title on startup. So please don't rely on the title

    // Don't tile:
    // - Chrome cmd+f window ("AXUnknown" value)
    // - login screen (Yes fuck, it's also a window from Apple's API perspective) ("AXUnknown" value)
    // - XCode "Build succeeded" popup
    // - IntelliJ tooltips, context menus, drop downs
    // - macOS native file picker (IntelliJ -> "Open...") (kAXDialogSubrole value)
    //
    // Minimized windows or windows of a hidden app have subrole "AXDialog"
    if axWindow.get(Ax.subroleAttr) != kAXStandardWindowSubrole {
        return true
    }
    // Firefox: Picture in Picture window doesn't have minimize button.
    // todo. bug: when firefox shows non-native fullscreen, minimize button is disabled for all other windows
    if app.isFirefox() && axWindow.get(Ax.minimizeButtonAttr)?.get(Ax.enabledAttr) != true {
        return true
    }
    if app.id == "com.apple.PhotoBooth" { return true }
    // Heuristic: float windows without fullscreen button (such windows are not designed to be big)
    // - IntelliJ various dialogs (Rebase..., Edit commit message, Settings, Project structure)
    // - Finder copy file dialog
    // - System Settings
    // - Apple logo -> About this Mac
    // - Calculator
    // - Battle.net login dialog
    // Fullscreen button is presented but disabled:
    // - Safari -> Pinterest -> Log in with Google
    // - Kap screen recorder https://github.com/wulkano/Kap
    // - flameshot? https://github.com/nikitabobko/AeroSpace/issues/112
    // - Drata Agent https://github.com/nikitabobko/AeroSpace/issues/134
    if !isFullscreenable(axWindow) &&
        app.id != "org.gimp.gimp-2.10" && // Gimp doesn't show fullscreen button
        app.id != "com.apple.ActivityMonitor" && // Activity Monitor doesn't show fullscreen button

        // Terminal apps and Emacs have an option to hide their title bars
        app.id != "org.alacritty" && // ~/.alacritty.toml: window.decorations = "Buttonless"
        app.id != "net.kovidgoyal.kitty" && // ~/.config/kitty/kitty.conf: hide_window_decorations titlebar-and-corners
        app.id != "com.mitchellh.ghostty" && // ~/.config/ghostty/config: window-decoration = false
        app.id != "com.github.wez.wezterm" &&
        app.id != "com.googlecode.iterm2" &&
        app.id != "org.gnu.Emacs"
    {
        return true
    }
    return false
}

private func isFullscreenable(_ axWindow: AXUIElement) -> Bool {
    if let fullscreenButton = axWindow.get(Ax.fullscreenButtonAttr) {
        return fullscreenButton.get(Ax.enabledAttr) == true
    }
    return false
}

extension Window {
    func relayoutWindow(on workspace: Workspace, forceTile: Bool = false) {
        unbindFromParent() // It's important to unbind to get correct data from getBindingData*
        let data = forceTile
            ? getBindingDataForNewTilingWindow(workspace)
            : getBindingDataForNewWindow(self.asMacWindow().axWindow, workspace, self.macAppUnsafe)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's "unsafe". It requires the window to be in unbound state
// @MainActor
private func getBindingDataForNewWindow(_ axWindow: AXUIElement, _ workspace: Workspace, _ app: MacApp) -> BindingData {
    if !isWindow(axWindow, app) {
        return BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    if isDialogHeuristic(axWindow, app) {
        return BindingData(parent: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    return getBindingDataForNewTilingWindow(workspace)
}

// The function is private because it's unsafe. It requires the window to be in unbound state
private func getBindingDataForNewTilingWindow(_ workspace: Workspace) -> BindingData {
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex + 1
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST
        )
    }
}

extension UnsafeMutableRawPointer {
    var window: MacWindow? { Unmanaged.fromOpaque(self).takeUnretainedValue() }
}

@MainActor
func tryOnWindowDetected(_ window: Window, startup: Bool) async throws(CancellationError) {
    switch window.parent.cases {
        case .tilingContainer, .workspace, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await onWindowDetected(window, startup: startup)
        case .macosPopupWindowsContainer:
            break
    }
}

@MainActor
private func onWindowDetected(_ window: Window, startup: Bool) async throws(CancellationError) {
    for callback in config.onWindowDetected where callback.matches(window, startup: startup) {
        _ = try await callback.run.runCmdSeq(.defaultEnv.copy(\.windowId, window.windowId), .emptyStdin)
        if !callback.checkFurtherCallbacks {
            return
        }
    }
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window, startup: Bool) -> Bool {
        if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != startup {
            return false
        }
        if let regex = matcher.windowTitleRegexSubstring, !(window.title).contains(regex) {
            return false
        }
        if let appId = matcher.appId, appId != window.app.id {
            return false
        }
        if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(regex) {
            return false
        }
        if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}
