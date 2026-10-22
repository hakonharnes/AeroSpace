import AppKit
import Common

/// Persists the layout (the tree of every workspace, floating windows, which workspace is on which monitor, the
/// focused workspace) to disk, so that it survives AeroSpace restarts (updates, crashes).
///
/// macOS window ids are stable as long as the app is running, that's all we need: restarting AeroSpace doesn't
/// restart the apps. After a reboot, the ids change (and can be reused by other windows), that's why the snapshot
/// remembers the boot time and is ignored after a reboot. https://github.com/nikitabobko/AeroSpace/issues/152
///
/// The restore itself reuses the lock screen machinery: the snapshot is loaded into closedWindowsCache before the
/// startup refresh session, and every detected window that is in the snapshot puts the world back. See closedWindowsCache

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
    let world = FrozenWorld(
        workspaces: Workspace.all.map { FrozenWorkspace($0) },
        monitors: monitorInfos.map(FrozenMonitor.init),
        windowIds: Workspace.all.flatMap { collectAllWindowIdsRecursive($0) }.toSet(),
        focusedWorkspace: focus.workspace.name,
        bootTime: bootTime,
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(world), data != lastPersistedLayout else { return }
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
          let world = try? JSONDecoder().decode(FrozenWorld.self, from: data),
          world.bootTime == bootTime // Window ids are not stable across reboots
    else { return nil }
    seedClosedWindowsCache(world)
    return world.focusedWorkspace
}
