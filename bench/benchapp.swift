// A tiny Cocoa app used by bench.swift as a controllable window source.
//
// Usage: benchapp --name <name> [--windows <n>] [--slow-ms <ms>] [--quit-on-last-close] [--stats <path>]
//   SIGUSR1 closes the most recently opened window (app-initiated close, like cmd-w)
//   --slow-ms   Block the main thread for <ms> every 50ms to emulate an app that is slow at answering AX requests
//   --stats     Periodically dump counters (window moves, resizes, AX writes) as JSON to <path>
import AppKit

nonisolated(unsafe) var axPositionWrites = 0
nonisolated(unsafe) var axSizeWrites = 0
nonisolated(unsafe) var moves = 0
nonisolated(unsafe) var resizes = 0

final class BenchWindow: NSWindow {
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        switch attribute {
            case .position: axPositionWrites += 1
            case .size: axSizeWrites += 1
            default: break
        }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

struct Args {
    var name = "bench"
    var windows = 1
    var slowMs = 0
    var quitOnLastClose = false
    var stats: String? = nil
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
            case "--name": args.name = it.next()!
            case "--windows": args.windows = Int(it.next()!)!
            case "--slow-ms": args.slowMs = Int(it.next()!)!
            case "--quit-on-last-close": args.quitOnLastClose = true
            case "--stats": args.stats = it.next()!
            default: fatalError("Unknown arg \(arg)")
        }
    }
    return args
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let args: Args
    var windows: [NSWindow] = []
    var closeSource: (any DispatchSourceSignal)? = nil
    init(_ args: Args) { self.args = args }

    func applicationDidFinishLaunching(_: Notification) {
        for i in 0 ..< args.windows {
            let w = BenchWindow(
                contentRect: NSRect(x: 100 + i * 30, y: 100 + i * 30, width: 500, height: 400),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false,
            )
            w.title = "\(args.name)-\(i)"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        signal(SIGUSR1, SIG_IGN)
        let closeSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        closeSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.windows.popLast()?.close() }
        }
        closeSource.resume()
        self.closeSource = closeSource
        if args.slowMs > 0 {
            let slow = args.slowMs
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in usleep(UInt32(slow * 1000)) }
        }
        if let stats = args.stats {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let json = "{\"pid\":\(getpid()),\"moves\":\(moves),\"resizes\":\(resizes),\"axPositionWrites\":\(axPositionWrites),\"axSizeWrites\":\(axSizeWrites)}"
                try? json.write(toFile: stats, atomically: true, encoding: .utf8)
            }
        }
    }

    let frameLog = ProcessInfo.processInfo.environment["BENCHAPP_FRAME_LOG"]
    func logFrame(_ kind: String, _ n: Notification) {
        guard let frameLog, let w = n.object as? NSWindow else { return }
        let line = String(format: "%.1f %@ %@ %@\n", Double(DispatchTime.now().uptimeNanoseconds) / 1e6, w.title, kind, NSStringFromRect(w.frame))
        if let h = FileHandle(forWritingAtPath: frameLog) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(toFile: frameLog, atomically: false, encoding: .utf8) }
    }
    func windowDidMove(_ n: Notification) { moves += 1; logFrame("move", n) }
    func windowDidResize(_ n: Notification) { resizes += 1; logFrame("resize", n) }
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { args.quitOnLastClose }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate(parseArgs())
app.delegate = delegate
app.run()
