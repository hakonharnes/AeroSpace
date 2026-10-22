import AppKit
import Common

/// The subscription is active as long as you keep this class in memory
final class AxSubscription {
    let obs: AXObserver
    let ax: AXUIElement
    let axThreadToken: AxAppThreadToken = axTaskLocalAppThreadToken ?? dieT("axTaskLocalAppThreadToken is not initialized")
    var notifKeys: Set<String> = []

    private init(obs: AXObserver, ax: AXUIElement) {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        self.obs = obs
        self.ax = ax
    }

    private func subscribe(_ key: String, _ refcon: UnsafeMutableRawPointer?) throws -> Bool {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        if unsafe AXObserverAddNotification(obs, ax, key as CFString, refcon) == .success {
            notifKeys.insert(key)
            return true
        } else {
            return false
        }
    }

    /// - Parameter refcon: passed to the handlers as is. The handlers of a destroyed element can't ask the element
    ///   anything anymore, that's how they learn which window it was
    static func bulkSubscribe(
        _ nsApp: NSRunningApplication,
        _ ax: AXUIElement,
        _ job: RunLoopJob,
        _ handlerToNotifKeyMapping: HandlerToNotifKeyMapping,
        refcon: UnsafeMutableRawPointer? = nil,
    ) throws -> [AxSubscription] {
        var result: [AxSubscription] = []
        var visitedNotifKeys: Set<String> = []
        for unsafe (handler, notifKeys) in unsafe handlerToNotifKeyMapping {
            try job.checkCancellation()
            guard let obs = unsafe AXObserver.new(nsApp.processIdentifier, handler) else { return [] }
            let subscription = AxSubscription(obs: obs, ax: ax)
            for key: String in notifKeys {
                try job.checkCancellation()
                assert(visitedNotifKeys.insert(key).inserted)
                if try unsafe !subscription.subscribe(key, refcon) { return [] }
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            result.append(subscription)
        }
        return result
    }

    deinit {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for notifKey in notifKeys {
            AXObserverRemoveNotification(obs, ax, notifKey as CFString)
        }
    }
}

typealias HandlerToNotifKeyMapping = [(AXObserverCallback, [String])]
