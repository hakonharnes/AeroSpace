import AppKit
import Carbon
import Common
import IOKit
import SwiftUI

/// Distance of the badge from the bottom-right corner of the main monitor
private let badgeMargin: CGFloat = 20
private let badgeHeight: CGFloat = 44
private let cardSize = CGSize(width: 460, height: 110)
/// Room around the badge for its shadow
private let shadowMargin: CGFloat = 12
/// The pill grows to the card and back
private let transitionDuration: TimeInterval = 0.25

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

/// What the badge shows. The panel changes it, with an animation for the hover transition
@MainActor
final class SecureInputBadgeModel: ObservableObject {
    @Published var holder: SecureInputHolder? = nil
    @Published var pillSize: CGSize = .zero
    @Published var isExpanded = false
}

public final class SecureInputPanel: NSPanelHud {
    @MainActor public static var shared: SecureInputPanel = SecureInputPanel()
    private let model: SecureInputBadgeModel
    private let hostingView: NSHostingView<SecureInputView>
    private var shownHolder: SecureInputHolder? = nil
    /// Whether the window has the card's size. Lags behind the model while the card collapses
    private var isExpanded = false
    private var pollTimer: Timer? = nil

    @MainActor
    override private init() {
        model = SecureInputBadgeModel()
        hostingView = NSHostingView(rootView: SecureInputView(model: model))
        super.init()
        self.acceptsMouseMovedEvents = true // Hover expands the badge
        self.hasShadow = false // The badge draws its own. The window's shadow wouldn't follow the transition
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
            model.holder = holder
            model.pillSize = NSHostingView(rootView: SecureInputPill(holder: holder)).fittingSize
            model.isExpanded = false
            fitWindow()
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

    /// The badge animates between the pill and the card within a window of the card's size. The window is only that
    /// big while the card is shown, so that the pill doesn't take the clicks around it
    @MainActor
    fileprivate func setExpanded(_ expanded: Bool) {
        if isExpanded == expanded && model.isExpanded == expanded { return }
        if expanded {
            isExpanded = true
            fitWindow()
        }
        withAnimation(.smooth(duration: transitionDuration)) { model.isExpanded = expanded }
        if !expanded {
            Task.startUnstructured { @MainActor in
                try? await Task.sleep(for: .seconds(transitionDuration + 0.05))
                let panel = SecureInputPanel.shared
                if !panel.model.isExpanded && panel.isExpanded {
                    panel.isExpanded = false
                    panel.fitWindow()
                }
            }
        }
    }

    @MainActor
    fileprivate func onClick() {
        guard let holder = shownHolder, !holder.isLoginWindow else { return }
        jumpToSecureInputHolder(holder)
    }

    /// The badge sits in the bottom-right corner of the main monitor. The SwiftUI view always has the card's size and
    /// draws the badge in its bottom-right corner; the window shows the part of it that the badge needs
    @MainActor
    private func fitWindow() {
        let badge = isExpanded ? cardSize : model.pillSize
        let full = CGSize(width: cardSize.width + 2 * shadowMargin, height: cardSize.height + 2 * shadowMargin)
        let size = CGSize(width: badge.width + 2 * shadowMargin, height: badge.height + 2 * shadowMargin)
        let x = mainMonitorInfo.width - badgeMargin - badge.width - shadowMargin
        self.setFrame(NSRect(x: x, y: badgeMargin - shadowMargin, width: size.width, height: size.height), display: true)
        hostingView.frame = NSRect(x: size.width - full.width, y: 0, width: full.width, height: full.height)
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

/// A pill in the bottom-right corner: a lock and the icon of the app that holds secure input. On hover, it grows to a
/// card that explains what's going on
struct SecureInputView: View {
    @ObservedObject var model: SecureInputBadgeModel
    private var holder: SecureInputHolder? { model.holder }

    private var title: String {
        guard let holder else { return "Secure input is on" }
        if holder.isLoginWindow { return "macOS left secure input on" }
        return "\(holder.name) has secure input on"
    }

    private var details: String {
        let cantSee = "AeroSpace can't see your keyboard shortcuts."
        guard let holder else { return "\(cantSee) Secure input is a macOS security feature that prevents apps from reading keyboard events." }
        if holder.isLoginWindow { return "\(cantSee) Lock and unlock the screen (ctrl-cmd-Q) to release it." }
        return "\(cantSee) Click to switch to \(holder.name). Click again for its next window."
    }

    /// Both the pill and the card are always there, in the bottom-right corner of the badge. The transition fades
    /// one into the other while the badge grows or shrinks, revealing the card from the corner
    var body: some View {
        let expanded = model.isExpanded
        ZStack(alignment: .bottomTrailing) {
            card.opacity(expanded ? 1 : 0)
            SecureInputPill(holder: holder).opacity(expanded ? 0 : 1)
        }
        .frame(
            width: expanded ? cardSize.width : model.pillSize.width,
            height: expanded ? cardSize.height : model.pillSize.height,
            alignment: .bottomTrailing,
        )
        .clipShape(badgeShape)
        .notificationBackground(badgeShape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .contentShape(badgeShape)
        .onHover { SecureInputPanel.shared.setExpanded($0) }
        .onTapGesture { SecureInputPanel.shared.onClick() }
        .help(holder.map { "Secure input is held by \($0.name) (pid \($0.pid))" } ?? "Secure input is on")
        .padding(shadowMargin)
        .frame(width: cardSize.width + 2 * shadowMargin, height: cardSize.height + 2 * shadowMargin, alignment: .bottomTrailing)
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

/// Like a macOS notification banner
private let badgeShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

struct SecureInputPill: View {
    let holder: SecureInputHolder?

    var body: some View {
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
        .fixedSize()
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
