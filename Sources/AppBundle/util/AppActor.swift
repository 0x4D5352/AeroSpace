import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class AppActor {
    /*conform*/ let pid: Int32
    /*conform*/ let id: String? // todo rename to bundleId
    let nsApp: NSRunningApplication
    private let axApp: UnsafeSendable<AXUIElement>
    let isZoom: Bool
    private let axObservers: UnsafeSendable<[AxObserverWrapper]> // keep observers in memory
    private let windows: MutableUnsafeSendable<[UInt32: AXUIElement]> = .init([:])
    private var thread: Thread?

    /*conform*/ var name: String? { nsApp.localizedName }
    /*conform*/ var execPath: String? { nsApp.executableURL?.path }
    /*conform*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: AppActor] = [:]
    @MainActor private static var wipPids: Set<pid_t> = []

    private init(_ nsApp: NSRunningApplication, _ axApp: AXUIElement, _ axObservers: [AxObserverWrapper], _ thread: Thread) {
        self.pid = nsApp.processIdentifier
        self.id = nsApp.bundleIdentifier
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.axObservers = .init(axObservers)
        self.thread = thread
        self.isZoom = nsApp.bundleIdentifier == "us.zoom.xos"
    }

    @MainActor
    private static func get(_ nsApp: NSRunningApplication) async throws(CancellationError) -> AppActor? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId {
            return nil
        }
        let pid = nsApp.processIdentifier
        if let existing = allAppsMap[pid] {
            return existing
        } else {
            try checkCancellation()
            if !wipPids.insert(pid).inserted { return nil } // todo think if it's better to wait or return nil
            defer { wipPids.remove(pid) }
            let app = await withCheckedContinuation { (cont: Continuation<AppActor?>) in
                let thread = Thread {
                    let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                    var observers: [AxObserverWrapper] = []
                    if observe(refreshObs, axApp, nsApp, kAXWindowCreatedNotification, &observers) &&
                        observe(refreshObs, axApp, nsApp, kAXFocusedWindowChangedNotification, &observers)
                    {
                        let app = AppActor(nsApp, axApp, observers, Thread.current)
                        cont.resume(returning: app)
                    } else {
                        unsubscribeAxObservers(observers)
                        cont.resume(returning: nil)
                    }
                    CFRunLoopRun()
                }
                thread.name = "app-dedicated-thread pid=\(pid) \(nsApp.bundleIdentifier ?? nsApp.executableURL?.description ?? "")"
                thread.start()
            }
            if let app {
                allAppsMap[pid] = app
                return app
            } else {
                return nil
            }
        }
    }

    func closeWindow(_ windowId: UInt32) async throws(CancellationError) -> Bool {
        try await withWindow(windowId) { window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return false }
            if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) != AXError.success { return false }
            return true
        } == true
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(startup: Bool) async throws(CancellationError) -> Window? {
        try await getThreadOrThrow().runInLoop { job in
            axApp.unsafe.get(Ax.focusedWindowAttr)
        }
        // getFocusedAxWindow()?.lets { MacWindow.get(app: self, axWindow: $0, startup: startup) }
    }

    func nativeFocusAsync(_ windowId: UInt32) {
        withWindowAsync(windowId) { [nsApp] window, job in
            // Raise firstly to make sure that by the time we activate the app, the window would be already on top
            window.set(Ax.isMainAttr, true)
            _ = window.raise()
            nsApp.activate(options: .activateIgnoringOtherApps)
        }
    }

    private var setFrameJob: RunLoopJob? = nil
    func setFrameAsync(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJob?.cancel()
        setFrameJob = withWindowAsync(windowId) { [axApp] window, job in
            disableAnimations(app: axApp.unsafe) {
                _setFrame(window, topLeft, size)
            }
        }
    }

    func setAxFrameDuringTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) async throws(CancellationError) {
        setFrameJob?.cancel()
        try await withWindow(windowId) { [axApp] window, job in
            disableAnimations(app: axApp.unsafe) {
                _setFrame(window, topLeft, size)
            }
        }
    }

    func setSizeAsync(_ windowId: UInt32, _ size: CGSize) {
        setFrameJob?.cancel()
        setFrameJob = withWindowAsync(windowId) { [axApp] window, job in
            disableAnimations(app: axApp.unsafe) {
                _ = window.set(Ax.sizeAttr, size)
            }
        }
    }

    func setTopLeftCornerAsync(_ windowId: UInt32, _ point: CGPoint) {
        setFrameJob?.cancel()
        setFrameJob = withWindowAsync(windowId) { [axApp] window, job in
            disableAnimations(app: axApp.unsafe) {
                _ = window.set(Ax.topLeftCornerAttr, point)
            }
        }
    }

    func getWindowsCount() async throws(CancellationError) -> Int? {
        try await getThreadOrThrow().runInLoop { [axApp] job in
            axApp.unsafe.get(Ax.windowsAttr)?.count
        }
    }

    func getTopLeftCorner(_ windowId: UInt32) async throws(CancellationError) -> CGPoint? {
        try await withWindow(windowId) { window, job in
            window.get(Ax.topLeftCornerAttr)
        }
    }

    func getRect(_ windowId: UInt32) async throws(CancellationError) -> Rect? {
        try await withWindow(windowId) { window, job in
            guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
            guard let size = window.get(Ax.sizeAttr) else { return nil }
            return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
        }
    }

    func isWindow(_ windowId: UInt32) async throws(CancellationError) -> Bool {
        try await withWindow(windowId) { [axApp, id] window, job in
            isWindowImpl(axWindow: window, axApp: axApp.unsafe, appBundleId: id)
        } == true
    }

    func setNativeFullscreenAsync(_ windowId: UInt32, _ value: Bool) {
        withWindowAsync(windowId) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    // @MainActor
    // static func detectNewAppsAndWindows(startup: Bool) async throws(CancellationError) {
    //     var result = [any AbstractApp]()
    //     for _app in NSWorkspace.shared.runningApplications where _app.activationPolicy == .regular {
    //         let app = try await AppActor.get(_app)
    //         if let app = _app.macApp {
    //             result.append(app)
    //         }
    //     }
    //     return result
    // }

    // func detectNewWindows(startup: Bool) async throws(CancellationError) {
    //     try checkCancellation()
    //     await thread?.runInLoop { job in
    //         guard let windows = axApp.unsafe.get(Ax.windowsAttr, signpostEvent: name) else { return }
    //         for window in windows {
    //             _ = MacWindow.get(app: self, axWindow: window, startup: startup)
    //         }
    //     }
    // }

    // func gcWindowsAsync(frontmostAppBundleId: String) {
    //     // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
    //     // Second and third lines of defence are technically needed only to avoid potential flickering
    //     if frontmostAppBundleId == lockScreenAppBundleId { return }
    //     let windows = windows
    //     thread.runInLoopAsync {
    //         let toKill = windows.filter { $0.value.unsafe.containingWindowId(signpostEvent: bundleId) == nil }
    //         // If all windows are "unobservable", it's highly propable that loginwindow might be still active and we are still
    //         // recovering from unlock
    //         if toKill.count == windows.count { return }
    //         for window in toKill {
    //             window.value.unsafe.garbageCollect(skipClosedWindowsCache: false) // todo
    //         }
    //     }
    // }

    @MainActor
    private func garbageCollect(skipClosedWindowsCache: Bool) { // todo try to convert to deinit
        AppActor.allAppsMap.removeValue(forKey: nsApp.processIdentifier)
        MacWindow.allWindows.lazy.filter { $0.app.pid == self.pid }.forEach { $0.garbageCollect(skipClosedWindowsCache: skipClosedWindowsCache) }
        thread?.runInLoopAsync { [axObservers] job in
            unsubscribeAxObservers(axObservers.unsafe)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil // Disallow all future job submissions
    }

    @MainActor
    static func garbageCollectTerminatedApps() {
        for app in allAppsMap.values where app.nsApp.isTerminated {
            app.garbageCollect(skipClosedWindowsCache: true)
        }
    }

    func setNativeMinimizedAsync(_ windowId: UInt32, _ value: Bool) {
        withWindowAsync(windowId) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    private func getThreadOrThrow() throws(CancellationError) -> Thread { // todo rename to "OrThrowCancellation"
        if let thread { return thread }
        throw CancellationError()
    }

    private func withWindow<T>(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) -> T?) async throws(CancellationError) -> T? {
        try await getThreadOrThrow().runInLoop { [windows] job in
            guard let window = windows.unsafe[windowId] else { return nil }
            return body(window, job)
        }
    }

    @discardableResult
    private func withWindowAsync(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) -> ()) -> RunLoopJob {
        thread?.runInLoopAsync { [windows] job in
            guard let window = windows.unsafe[windowId] else { return }
            body(window, job)
        } ?? .cancelled
    }
}

private func _setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?) {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    if let size { window.set(Ax.sizeAttr, size) }
}

private func observe(
    _ handler: AXObserverCallback,
    _ axApp: AXUIElement,
    _ nsApp: NSRunningApplication,
    _ notifKey: String,
    _ observers: inout [AxObserverWrapper]
) -> Bool {
    guard let observer = AXObserver.observe(nsApp.processIdentifier, notifKey, axApp, handler, data: nil) else { return false }
    observers.append(AxObserverWrapper(obs: observer, ax: axApp, notif: notifKey as CFString))
    return true
}

private func unsubscribeAxObservers(_ observers: [AxObserverWrapper]) {
    for obs in observers {
        AXObserverRemoveNotification(obs.obs, obs.ax, obs.notif)
    }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ body: () -> T) -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    let result = body()
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, true)
    }
    return result
}

public final class MutableUnsafeSendable<T>: Sendable {
    nonisolated(unsafe) var unsafe: T
    public init(_ value: T) { self.unsafe = value }
}

public final class UnsafeSendable<T>: Sendable {
    nonisolated(unsafe) let unsafe: T
    public init(_ value: T) { self.unsafe = value }
}

public typealias Continuation<T> = CheckedContinuation<T, Never>

// var allAppsMap: Bar = Bar()

// public struct NonSendable {
//     func foo() {}
// }
//
// actor Foo {
//     let foo: NonSendable
//
//     init(foo: NonSendable) {
//         self.foo = foo
//     }
// }
//
// func foo() {
//     let bar = NonSendable()
//     let foo = Foo(foo: bar)
//     bar.foo()
// }
