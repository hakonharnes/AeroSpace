// Benchmark driver for AeroSpace. See bench/README.md
//
// Usage: bench --cli <path-to-aerospace-cli> --server-pid <pid> --stats-dir <dir> [--iterations <n>] [--label <label>]
//
// Expects two workspaces BENCH_A and BENCH_B populated with benchapp windows (run-bench.sh does that)
import AppKit
import CoreGraphics
import Foundation

struct Args {
    var cli = "aerospace"
    var serverPid: pid_t = 0
    var statsDir = ""
    var iterations = 30
    var label = "run"
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
            case "--cli": args.cli = it.next()!
            case "--server-pid": args.serverPid = pid_t(it.next()!)!
            case "--stats-dir": args.statsDir = it.next()!
            case "--iterations": args.iterations = Int(it.next()!)!
            case "--label": args.label = it.next()!
            default: fatalError("Unknown arg \(arg)")
        }
    }
    return args
}

let args = parseArgs()

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 } // ms

// posix_spawn + waitpid. Foundation's Process.waitUntilExit polls with ~100ms granularity which ruins measurements
@discardableResult
func cli(_ cliArgs: String...) -> String {
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&actions, fds[0])
    let argv: [UnsafeMutablePointer<CChar>?] = ([args.cli] + cliArgs).map { strdup($0) } + [nil]
    var pid: pid_t = 0
    precondition(posix_spawn(&pid, args.cli, &actions, nil, argv, environ) == 0)
    close(fds[1])
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fds[0], &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    close(fds[0])
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return String(decoding: data, as: UTF8.self)
}

func windowIds(_ workspace: String) -> [CGWindowID] {
    cli("list-windows", "--workspace", workspace, "--format", "%{window-id}")
        .split(separator: "\n").compactMap { CGWindowID($0.trimmingCharacters(in: .whitespaces)) }
}

func bounds(_ ids: [CGWindowID]) -> [CGWindowID: CGRect] {
    // The array must contain raw CGWindowIDs, not boxed objects. Hence CFArrayCreate with nil callbacks
    var ptrs = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    let arr = CFArrayCreate(nil, &ptrs, ptrs.count, nil)
    guard let info = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [:] }
    var result: [CGWindowID: CGRect] = [:]
    for w in info {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { continue }
        // Windows parked off-screen might be reported as 1x1 windows in the middle of the display
        result[id] = (w[kCGWindowIsOnscreen as String] as? Bool) == true ? rect : .null
    }
    return result
}

let displays: [CGRect] = {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}()

func visibleFraction(_ r: CGRect) -> Double {
    if r.isNull { return 0 }
    let area = r.width * r.height
    if area <= 0 { return 0 }
    return displays.map { $0.intersection(r) }.filter { !$0.isNull }.map { $0.width * $0.height }.reduce(0, +) / area
}

func isHidden(_ r: CGRect) -> Bool { visibleFraction(r) < 0.05 }

func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

func cpuMs(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if ok != 0 { return .nan }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

struct AppStats: Decodable { let pid: Int32; let moves: Int; let resizes: Int; let axPositionWrites: Int; let axSizeWrites: Int }

func readStats() -> [AppStats] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: args.statsDir)) ?? []
    return files.filter { $0.hasSuffix(".json") }.compactMap {
        try? JSONDecoder().decode(AppStats.self, from: Data(contentsOf: URL(filePath: args.statsDir + "/" + $0)))
    }
}

func sumStats(_ s: [AppStats]) -> (writes: Int, frameChanges: Int, appCpuMs: Double) {
    (s.map { $0.axPositionWrites + $0.axSizeWrites }.reduce(0, +), s.map { $0.moves + $0.resizes }.reduce(0, +), s.map { cpuMs($0.pid) }.reduce(0, +))
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    if s.isEmpty { return .nan }
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

// ---------- Setup ----------
let wsA = "BENCH_A"
let wsB = "BENCH_B"
let idsA = windowIds(wsA)
let idsB = windowIds(wsB)
precondition(!idsA.isEmpty && !idsB.isEmpty, "Populate \(wsA) and \(wsB) first")

func settle() { usleep(600_000) }
cli("workspace", wsA); settle()
let expectedA = bounds(idsA)
cli("workspace", wsB); settle()
let expectedB = bounds(idsB)

// ---------- Workspace switch ----------
var settleTimes: [Double] = []
var shownTimes: [Double] = []
var hiddenTimes: [Double] = []
var blankTimes: [Double] = []
var cliTimes: [Double] = []
var timeouts = 0
let statsBefore = sumStats(readStats())
let serverCpuBefore = cpuMs(args.serverPid)
for i in 0 ..< args.iterations {
    let (target, shown, hidden, expected) = i % 2 == 0 ? (wsA, idsA, idsB, expectedA) : (wsB, idsB, idsA, expectedB)
    let t0 = now()
    if let timeline = ProcessInfo.processInfo.environment["BENCH_TIMELINE"] {
        let line = String(format: "T0 %.1f %@\n", t0, target)
        if let h = FileHandle(forWritingAtPath: timeline) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(toFile: timeline, atomically: false, encoding: .utf8) }
    }
    let p = Process()
    p.executableURL = URL(filePath: args.cli)
    p.arguments = ["workspace", target]
    try! p.run()
    var cliDone: Double? = nil
    var allHiddenAt: Double? = nil
    var allShownAt: Double? = nil
    while now() - t0 < 3000 {
        if cliDone == nil && !p.isRunning { cliDone = now() - t0 }
        let b = bounds(shown + hidden)
        if allHiddenAt == nil && hidden.allSatisfy({ b[$0].map(isHidden) ?? true }) { allHiddenAt = now() - t0 }
        if allShownAt == nil && shown.allSatisfy({ id in b[id].map { r in expected[id].map { close(r, $0) } ?? false } ?? false }) {
            allShownAt = now() - t0
        }
        if allHiddenAt != nil && allShownAt != nil && cliDone != nil { break }
        usleep(500)
    }
    p.waitUntilExit()
    if let allHiddenAt, let allShownAt {
        settleTimes.append(max(allHiddenAt, allShownAt))
        shownTimes.append(allShownAt)
        hiddenTimes.append(allHiddenAt)
        // How long the screen showed "holes": old windows already gone, new ones not yet in place
        blankTimes.append(max(0, allShownAt - allHiddenAt))
    } else {
        if timeouts == 0 {
            let b = bounds(shown + hidden)
            print("timeout: target=\(target) hiddenOk=\(allHiddenAt != nil) shownOk=\(allShownAt != nil)")
            for id in shown { print("  shown \(id) actual=\(b[id].map { "\($0)" } ?? "nil") expected=\(expected[id].map { "\($0)" } ?? "nil")") }
            for id in hidden { print("  hidden \(id) actual=\(b[id].map { "\($0)" } ?? "nil") visible=\(b[id].map(visibleFraction) ?? -1)") }
        }
        timeouts += 1
    }
    cliTimes.append(cliDone ?? (now() - t0))
    usleep(250_000) // Let trailing refresh sessions run, they are part of the measured CPU cost
}
let serverCpuAfter = cpuMs(args.serverPid)
let statsAfter = sumStats(readStats())

// ---------- Idle churn: AX writes while nothing happens ----------
let idleBefore = sumStats(readStats())
usleep(2_000_000)
let idleAfter = sumStats(readStats())

// ---------- CLI query latency ----------
var queryTimes: [Double] = []
for _ in 0 ..< 40 {
    let t0 = now()
    cli("list-workspaces", "--focused")
    queryTimes.append(now() - t0)
}

let n = Double(args.iterations)
print("""
    == \(args.label) ==
    workspace switch (n=\(args.iterations), timeouts=\(timeouts))
      settle ms      p50=\(fmt(percentile(settleTimes, 0.5))) p90=\(fmt(percentile(settleTimes, 0.9))) max=\(fmt(settleTimes.max() ?? .nan))
      new shown ms   p50=\(fmt(percentile(shownTimes, 0.5))) p90=\(fmt(percentile(shownTimes, 0.9)))
      old hidden ms  p50=\(fmt(percentile(hiddenTimes, 0.5))) p90=\(fmt(percentile(hiddenTimes, 0.9)))
      holes ms       p50=\(fmt(percentile(blankTimes, 0.5))) p90=\(fmt(percentile(blankTimes, 0.9))) max=\(fmt(blankTimes.max() ?? .nan))
      cli ms         p50=\(fmt(percentile(cliTimes, 0.5))) p90=\(fmt(percentile(cliTimes, 0.9)))
      AX writes/switch      \(fmt(Double(statsAfter.writes - statsBefore.writes) / n))
      frame changes/switch  \(fmt(Double(statsAfter.frameChanges - statsBefore.frameChanges) / n))
      server cpu ms/switch  \(fmt((serverCpuAfter - serverCpuBefore) / n))
      apps cpu ms/switch    \(fmt((statsAfter.appCpuMs - statsBefore.appCpuMs) / n))
    idle (2s): AX writes=\(idleAfter.writes - idleBefore.writes)
    cli query 'list-workspaces --focused' ms  p50=\(fmt(percentile(queryTimes, 0.5))) p90=\(fmt(percentile(queryTimes, 0.9)))
    """)
