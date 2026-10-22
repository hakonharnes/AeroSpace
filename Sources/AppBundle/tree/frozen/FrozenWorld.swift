struct FrozenWorld: Codable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
    // Only used by the persisted layout
    var focusedWorkspace: String? = nil
    var bootTime: Int? = nil
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    var result = [UInt32]()
    for child in node.children {
        result += collectAllWindowIdsRecursive(child)
    }
    return result
}
