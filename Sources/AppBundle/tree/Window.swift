import AppKit
import Common

class Window: TreeNode, Hashable {
    nonisolated let windowId: UInt32
    let app: any AbstractApp
    override var parent: NonLeafTreeNodeObject { super.parent ?? errorT("Windows always have parent") }
    var parentOrNilForTests: NonLeafTreeNodeObject? { super.parent }
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? {
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func close() -> Bool {
        error("Not implemented")
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    @MainActor // todo can be dropped in future Swift versions?
    func getTopLeftCorner() async throws(CancellationError) -> CGPoint? { error("Not implemented") }
    func getSize() -> CGSize? { error("Not implemented") }
    var title: String { error("Not implemented") }
    var isMacosFullscreen: Bool { false }
    var isMacosMinimized: Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { error("Not implemented") }
    func nativeFocusAsync() { error("Not implemented") }
    @MainActor // todo can be dropped in future Swift versions
    func getRect() async throws(CancellationError) -> Rect? { error("Not implemented") }
    @MainActor // todo can be dropped in future Swift versions
    func getCenter() async throws(CancellationError) -> CGPoint? { try await getRect()?.center }

    func setTopLeftCornerAsync(_ point: CGPoint) { error("Not implemented") }
    func setAxFrameDuringTermination(_ topLeft: CGPoint?, _ size: CGSize?) async throws(CancellationError) { error("Not implemented") }
    func setFrameAsync(_ topLeft: CGPoint?, _ size: CGSize?) { error("Not implemented") }
    func setSizeAsync(_ size: CGSize) { error("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { parent is Workspace } // todo drop. It will be a source of bugs when sticky is introduced

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    var ownIndex: Int { ownIndexOrNil! }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
