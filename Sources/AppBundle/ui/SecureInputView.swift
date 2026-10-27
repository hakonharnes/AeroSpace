import AppKit
import Carbon
import Common
import IOKit
import SwiftUI

/// Distance of the badge from the bottom-right corner of the main monitor
private let badgeMargin: CGFloat = 20
private let badgeHeight: CGFloat = 44
private let cardSize = CGSize(width: 460, height: 110)

/// The app that holds Secure Event Input. While it's held, macOS doesn't deliver keyboard events to other apps,
/// so AeroSpace's key bindings don't work. Only the holder can release it (usually: its password field loses focus)
struct SecureInputHolder: Equatable {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    /// macOS sometimes leaves Secure Input held by loginwindow after unlocking the screen
    let isLoginWindow: Bool

    /// WindowServer publishes the holder in the IO registry, in the console user's session dictionary. It's the
    /// "responsible" app of the process that enabled Secure Input (e.g. the terminal for a `sudo` prompt)
    static var current: SecureInputHolder? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = unsafe IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as NSString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let session = users.first { ($0["kCGSSessionOnConsoleKey"] as? Bool) == true } ?? users.first
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return SecureInputHolder(
            pid: pid,
            name: app?.localizedName ?? "pid \(pid)",
            icon: app?.icon,
            isLoginWindow: app?.bundleIdentifier == lockScreenAppBundleId,
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid }
}

public final class SecureInputPanel: NSPanelHud {
    @MainActor public static var shared: SecureInputPanel = SecureInputPanel()
    private var hostingView = NSHostingView(rootView: SecureInputView(holder: nil, isExpanded: false))
    private var shownHolder: SecureInputHolder? = nil
    private var isExpanded = false
    private var pollTimer: Timer? = nil

    override private init() {
        super.init()
        self.acceptsMouseMovedEvents = true // Hover expands the badge
        self.contentView?.addSubview(hostingView)
    }

    @MainActor
    public func refresh() {
        startPollingIfNeeded()
        if let activeMode, TrayMenuModel.shared.isEnabled &&
            config.modes[activeMode]?.bindings.isEmpty == false && IsSecureEventInputEnabled()
        {
            let holder = SecureInputHolder.current
            if isVisible && holder == shownHolder { return }
            shownHolder = holder
            isExpanded = false
            render()
            self.orderFrontRegardless()
        } else {
            shownHolder = nil
            close()
        }
    }

    /// Secure Input usually starts and ends without any event that triggers a refresh session (and while it's on,
    /// key bindings don't trigger one either). Check once per second; both calls are cheap and local
    @MainActor
    private func startPollingIfNeeded() {
        if pollTimer != nil { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let panel = SecureInputPanel.shared
                if IsSecureEventInputEnabled() != panel.isVisible || (panel.isVisible && SecureInputHolder.current != panel.shownHolder) {
                    panel.refresh()
                }
            }
        }
    }

    @MainActor
    fileprivate func setExpanded(_ expanded: Bool) {
        if isExpanded == expanded { return }
        isExpanded = expanded
        render()
    }

    @MainActor
    fileprivate func onClick() {
        guard let holder = shownHolder, !holder.isLoginWindow else { return }
        jumpToSecureInputHolder(holder)
    }

    /// The badge grows up and to the left, from the bottom-right corner of the main monitor
    @MainActor
    private func render() {
        hostingView.rootView = SecureInputView(holder: shownHolder, isExpanded: isExpanded)
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        let x = mainMonitorInfo.width - size.width - badgeMargin
        self.setFrame(NSRect(x: x, y: badgeMargin, width: size.width, height: size.height), display: true)
    }
}

/// Focus the app that holds Secure Input (switching to its workspace), so the user can finish or cancel the password
/// prompt that holds it. Clicking again within a few seconds goes to the app's next window, in case the guess was wrong
@MainActor private var lastSecureInputJump: (pid: pid_t, windowId: UInt32, date: Date)? = nil
private let secureInputNextWindowPeriod: TimeInterval = 5

@MainActor
private func jumpToSecureInputHolder(_ holder: SecureInputHolder) {
    Task.startUnstructured { @MainActor in
        let app = MacApp.allAppsMap[holder.pid]
        let candidates = MacWindow.allWindows.filter { $0.macApp == app && $0.visualWorkspace != nil }
            .sorted { ($0.visualWorkspace?.name ?? "", $0.windowId) < ($1.visualWorkspace?.name ?? "", $1.windowId) }
        let window: MacWindow?
        if let last = lastSecureInputJump, last.pid == holder.pid, last.date.distance(to: .now) < secureInputNextWindowPeriod,
           let index = candidates.firstIndex(where: { $0.windowId == last.windowId }), candidates.count > 1
        {
            window = candidates[(index + 1) % candidates.count] // Repeated click: the next window of the app
        } else {
            // 1. The window with a focused password field: exact, if the app exposes it (Dia leaks Secure Input after
            //    the field loses focus, but the field stays focused in its window). Or the only window with a
            //    password field
            // 2. The app's own focused window. Apps report it even while in the background
            // 3. What AeroSpace saw focused last in this app (goes stale when the user switches the app's windows
            //    while another app is frontmost)
            let withSecureField = try? await app?.getWindowWithSecureTextField(.nonCancellable)
            let appFocused = try? await app?.getFocusedWindow(.nonCancellable)
            window = withSecureField.flatMap { id in candidates.first { $0.windowId == id } }
                ?? appFocused.flatMap { focused in candidates.first { $0 === focused } }
                ?? app?.lastNativeFocusedWindowId.flatMap { id in candidates.first { $0.windowId == id } }
                ?? candidates.first
        }
        if let window, let token = RunSessionGuard.isServerEnabled {
            lastSecureInputJump = (holder.pid, window.windowId, .now)
            _ = try? await runLightSession(.menuBarButton, token) { window.focusWindow() }
            window.nativeFocus()
        } else {
            let nsApp = NSRunningApplication(processIdentifier: holder.pid)
            nsApp?.unhide()
            nsApp?.activate(options: .activateAllWindows)
        }
    }
}

/// A pill in the bottom-right corner: a lock and the icon of the app that holds Secure Input. On hover, it grows to a
/// card that explains what's going on
struct SecureInputView: View {
    let holder: SecureInputHolder?
    let isExpanded: Bool

    /// Like a macOS notification banner
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    private var title: String {
        guard let holder else { return "Secure Input is on" }
        if holder.isLoginWindow { return "macOS left Secure Input on" }
        return "\(holder.name) has Secure Input on"
    }

    private var details: String {
        let cantSee = "AeroSpace can't see your keyboard shortcuts."
        guard let holder else { return "\(cantSee) Secure Input is a macOS security feature that prevents apps from reading keyboard events." }
        if holder.isLoginWindow { return "\(cantSee) Lock and unlock the screen (ctrl-cmd-Q) to release it." }
        return "\(cantSee) Click to switch to \(holder.name). Click again for its next window."
    }

    var body: some View {
        Group {
            if isExpanded { card } else { pill }
        }
        .notificationBackground(shape)
        .contentShape(shape)
        .onHover { SecureInputPanel.shared.setExpanded($0) }
        .onTapGesture { SecureInputPanel.shared.onClick() }
        .help(holder.map { "Secure Input is held by \($0.name) (pid \($0.pid))" } ?? "Secure Input is on")
        .fixedSize()
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.orange)
            if let icon = holder?.icon {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: badgeHeight)
    }

    private var card: some View {
        HStack(spacing: 10) {
            if let icon = holder?.icon {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.body)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: cardSize.width, height: cardSize.height)
    }
}

extension View {
    /// The material of macOS notification banners: Liquid Glass on macOS 26+, a translucent material before that
    @ViewBuilder
    fileprivate func notificationBackground(_ shape: RoundedRectangle) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
    }
}
