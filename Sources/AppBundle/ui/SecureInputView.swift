import AppKit
import Carbon
import Common
import IOKit
import SwiftUI

private let iconSize = CGSize(width: 50, height: 50)
private let textSize = CGSize(width: 460, height: 110)

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
    private var hostingView = NSHostingView(rootView: SecureInputView(holder: nil))
    private var shownHolder: SecureInputHolder? = nil
    private var pollTimer: Timer? = nil

    override private init() {
        super.init()
        self.acceptsMouseMovedEvents = true // Hover expands the badge
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
            self.contentView?.subviews.removeAll()
            hostingView = NSHostingView(rootView: SecureInputView(holder: holder))
            hostingView.frame = NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height)
            self.contentView?.addSubview(hostingView)
            let x = mainMonitorInfo.width - iconSize.width - 20
            let panelFrame = NSRect(x: x, y: 20, width: iconSize.width, height: iconSize.width)
            self.setFrame(panelFrame, display: true)
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

    public func updateFrame(isMinimized: Bool) {
        let width = isMinimized ? iconSize.width : textSize.width
        let height = isMinimized ? iconSize.height : textSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let x = mainMonitorInfo.width - width - 20
        let panelFrame = NSRect(x: x, y: 20, width: width, height: height)
        self.setFrame(panelFrame, display: true)
    }
}

/// Focus the app that holds Secure Input (switching to its workspace), so the user can finish or cancel the password
/// prompt that holds it
@MainActor
private func jumpToSecureInputHolder(_ holder: SecureInputHolder) {
    Task.startUnstructured { @MainActor in
        let app = MacApp.allAppsMap[holder.pid]
        let window = app.flatMap { app in
            app.lastNativeFocusedWindowId.flatMap { MacWindow.allWindowsMap[$0] }
                ?? MacWindow.allWindows.first { $0.macApp == app && $0.visualWorkspace != nil }
        }
        if let window, let token = RunSessionGuard.isServerEnabled {
            _ = try? await runLightSession(.menuBarButton, token) { window.focusWindow() }
            window.nativeFocus()
        } else {
            let nsApp = NSRunningApplication(processIdentifier: holder.pid)
            nsApp?.unhide()
            nsApp?.activate(options: .activateAllWindows)
        }
    }
}

struct SecureInputView: View {
    let holder: SecureInputHolder?
    @State var isMinimized: Bool = true

    @Environment(\.colorScheme) var colorScheme: ColorScheme
    private var fontColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var explanation: LocalizedStringKey {
        guard let holder else {
            return "AeroSpace cannot respond to keyboard shortcuts while **Secure Input** is active. **Secure Input** is a macOS security feature that prevents applications from reading keyboard events."
        }
        if holder.isLoginWindow {
            return "macOS left **Secure Input** on after unlocking the screen, so AeroSpace can't see your keyboard shortcuts. Lock and unlock the screen (ctrl-cmd-Q) to release it."
        }
        return "**\(holder.name)** has **Secure Input** on (a password field?), so AeroSpace can't see your keyboard shortcuts. Click to switch to \(holder.name)."
    }

    var body: some View {
        ZStack(alignment: .center) {
            Rectangle()
                .fill(Color.gray.opacity(isMinimized ? 0.8 : 1.0))
            if isMinimized {
                Image(systemName: "lock.shield.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
                if let icon = holder?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(1)
                }
            } else {
                HStack(spacing: 10) {
                    if let icon = holder?.icon {
                        Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                    }
                    Text(explanation)
                        .font(.title3)
                }
                .padding(10)
            }
        }
        .foregroundStyle(fontColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            isMinimized = !hovering
            SecureInputPanel.shared.updateFrame(isMinimized: isMinimized)
        }
        .onTapGesture {
            if let holder, !holder.isLoginWindow {
                jumpToSecureInputHolder(holder)
            } else {
                isMinimized.toggle()
                SecureInputPanel.shared.updateFrame(isMinimized: isMinimized)
            }
        }
        .help(holder.map { "Secure Input is held by \($0.name) (pid \($0.pid))" } ?? "Secure Input is on")
        .frame(
            width: isMinimized ? iconSize.width : textSize.width,
            height: isMinimized ? iconSize.height : textSize.height,
        )
    }
}
