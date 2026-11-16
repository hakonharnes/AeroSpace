import AppKit
import Common

/// Persists the layout (the tree of every workspace, floating windows, which workspace is on which monitor, the
/// focused workspace) to disk, so that it survives AeroSpace restarts (updates, crashes).
///
/// AeroSpace window ids (OpaqueWindowId) don't survive restarts, that's why the snapshot refers to the windows by
/// their macOS window ids. macOS window ids are stable as long as the app is running, that's all we need: restarting
/// AeroSpace doesn't restart the apps. After a reboot, the ids change (and can be reused by other windows), that's
/// why the snapshot remembers the boot time and is ignored after a reboot. https://github.com/nikitabobko/AeroSpace/issues/152
///
/// The restore itself reuses the lock screen machinery: the snapshot is loaded into closedWindowsCache before the
/// startup refresh session, and every detected window that is in the snapshot puts the world back. See closedWindowsCache.
/// The windows of the snapshot get their OpaqueWindowIds upfront. MacApp assigns them to the windows once it detects
/// them, see takePersistedOpaqueWindowId

private let persistedLayoutUrl: URL = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state")
    return stateHome.appending(path: "aerospace/layout.json")
}()

private let bootTime: Int = {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    return unsafe sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
}()

@MainActor private var lastPersistedLayout: Data? = nil
@MainActor private var persistLayoutTask: Task<(), Never>? = nil

/// Call it at the end of every refresh session. Writes only if something changed, debounced
@MainActor func persistLayoutIfNeeded() {
    if !config.restoreLayoutOnRestart || isStartup || isUnitTest { return }
    let layout = PersistedLayout(
        bootTime: bootTime,
        focusedWorkspace: globalFocus.workspace.name,
        monitors: globalUnsortedMonitorInfos.map(PersistedMonitor.init),
        workspaces: Workspace.all.map(PersistedWorkspace.init),
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(layout), data != lastPersistedLayout else { return }
    lastPersistedLayout = data
    persistLayoutTask?.cancel()
    persistLayoutTask = Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let url = persistedLayoutUrl
        await Task.detached {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }
}

/// Loads the snapshot of the previous AeroSpace instance into closedWindowsCache.
/// Returns the name of the previously focused workspace, or nil if there is nothing to restore
@MainActor func loadPersistedLayout() -> String? {
    if !config.restoreLayoutOnRestart || isUnitTest { return nil }
    guard let data = try? Data(contentsOf: persistedLayoutUrl),
          let (world, focusedWorkspace) = decodePersistedLayout(data, expectedBootTime: bootTime)
    else { return nil }
    seedClosedWindowsCache(world)
    return focusedWorkspace
}

/// Returns nil if the layout can't be decoded or was persisted before a reboot (window ids are not stable across reboots)
@MainActor func decodePersistedLayout(_ data: Data, expectedBootTime: Int) -> (world: FrozenWorld, focusedWorkspace: String?)? {
    guard let layout = try? JSONDecoder().decode(PersistedLayout.self, from: data), layout.bootTime == expectedBootTime else { return nil }
    return (layout.toFrozenWorld(), layout.focusedWorkspace)
}

/// macOS window id -> the id that the window had in the persisted layout
@MainActor private var persistedOpaqueWindowIds: [UInt32: (id: OpaqueWindowId, pid: pid_t?)] = [:]

/// Returns the id of the window in the persisted layout, if the window is there
@MainActor func takePersistedOpaqueWindowId(_ nativeWindowId: UInt32, pid: pid_t) -> OpaqueWindowId? {
    guard let entry = persistedOpaqueWindowIds[nativeWindowId] else { return nil }
    // A different pid means a different window that reuses the id
    guard entry.pid == nil || entry.pid == pid else { return nil }
    persistedOpaqueWindowIds[nativeWindowId] = nil
    return entry.id
}

/// The persisted layout is only restored at startup
@MainActor func forgetPersistedLayout() {
    persistedOpaqueWindowIds = [:]
}

// The format of the file. Don't change it in incompatible ways: the file is written by the previous AeroSpace version

private struct PersistedLayout: Codable {
    let bootTime: Int?
    let focusedWorkspace: String?
    let monitors: [PersistedMonitor]
    let workspaces: [PersistedWorkspace]

    @MainActor func toFrozenWorld() -> FrozenWorld {
        var windowIds: Set<OpaqueWindowId> = []
        func frozen(_ window: PersistedWindow) -> FrozenWindow {
            let id = OpaqueWindowId.nextUniqId()
            persistedOpaqueWindowIds[window.id] = (id, window.pid)
            windowIds.insert(id)
            return FrozenWindow(id: id, weight: window.weight)
        }
        func frozen(_ container: PersistedContainer) -> FrozenContainer {
            FrozenContainer(
                children: container.children.map {
                    switch $0 {
                        case .window(let w): .window(frozen(w))
                        case .container(let c): .container(frozen(c))
                    }
                },
                layout: container.layout,
                orientation: container.orientation,
                weight: container.weight,
            )
        }
        persistedOpaqueWindowIds = [:]
        var frozenMonitors: [FrozenMonitor] = []
        for monitor in monitors {
            let workspaces = workspaces.filter { $0.monitor.topLeftCorner == monitor.topLeftCorner }.map {
                FrozenWorkspace(
                    name: $0.name,
                    rootTilingNode: frozen($0.rootTilingNode),
                    floatingWindows: $0.floatingWindows.map(frozen),
                    macosUnconventionalWindows: $0.macosUnconventionalWindows.map(frozen),
                )
            }
            frozenMonitors.append(FrozenMonitor(
                visibleWorkspace: monitor.visibleWorkspace,
                topLeftCorner: monitor.topLeftCorner.asMyPoint,
                workspaces: workspaces,
            ))
        }
        return FrozenWorld(monitors: frozenMonitors, windowIds: windowIds)
    }
}

private struct PersistedMonitor: Codable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: MonitorInfo) {
        topLeftCorner = monitor.rect.topLeftCorner.asCGPoint
        visibleWorkspace = monitor.visibleWorkspace.name
    }
}

private struct PersistedWorkspace: Codable {
    let name: String
    let monitor: PersistedMonitor
    let rootTilingNode: PersistedContainer
    let floatingWindows: [PersistedWindow]
    let macosUnconventionalWindows: [PersistedWindow]

    @MainActor init(_ workspace: Workspace) {
        let frozen = FrozenWorkspace(workspace)
        name = frozen.name
        monitor = PersistedMonitor(workspace.workspaceMonitorInfo)
        rootTilingNode = PersistedContainer(frozen.rootTilingNode)
        floatingWindows = frozen.floatingWindows.compactMap(PersistedWindow.init)
        macosUnconventionalWindows = frozen.macosUnconventionalWindows.compactMap(PersistedWindow.init)
    }
}

private enum PersistedTreeNode: Codable {
    case container(PersistedContainer)
    case window(PersistedWindow)
}

private struct PersistedContainer: Codable {
    let children: [PersistedTreeNode]
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat

    @MainActor init(_ container: FrozenContainer) {
        children = container.children.compactMap {
            switch $0 {
                case .window(let w): PersistedWindow(w).map { .window($0) }
                case .container(let c): .container(PersistedContainer(c))
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = container.weight
    }
}

private struct PersistedWindow: Codable {
    /// macOS window id
    let id: UInt32
    /// The app that owned the window. A different pid means a different window that reuses the id
    let pid: pid_t?
    let weight: CGFloat

    @MainActor init?(_ window: FrozenWindow) {
        guard let macWindow = MacWindow.get(byId: window.id) as? MacWindow, let nativeWindowId = macWindow.nativeWindowId else { return nil }
        id = nativeWindowId
        pid = macWindow.app.pid
        weight = window.weight
    }
}

extension FrozenMonitor {
    init(visibleWorkspace: String, topLeftCorner: Point, workspaces: [FrozenWorkspace]) {
        self.visibleWorkspace = visibleWorkspace
        self.topLeftCorner = topLeftCorner
        self.workspaces = workspaces
    }
}

extension FrozenWorkspace {
    init(name: String, rootTilingNode: FrozenContainer, floatingWindows: [FrozenWindow], macosUnconventionalWindows: [FrozenWindow]) {
        self.name = name
        self.rootTilingNode = rootTilingNode
        self.floatingWindows = floatingWindows
        self.macosUnconventionalWindows = macosUnconventionalWindows
    }
}

extension FrozenContainer {
    init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }
}

extension FrozenWindow {
    init(id: OpaqueWindowId, weight: CGFloat) {
        self.id = id
        self.weight = weight
    }
}
