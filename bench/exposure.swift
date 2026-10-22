// Measures how much of the screen area covered by the given windows becomes uncovered (desktop shows through) while
// a command runs.
//
// Usage: exposure <duration-ms> <window-ids-comma-separated> <command> [args...]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let durationMs = Double(args[1])!
let ids = args[2].split(separator: ",").map { CGWindowID($0)! }
let command = Array(args.dropFirst(3))

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func onscreenRects() -> [CGRect] {
    var ptrs = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    let arr = CFArrayCreate(nil, &ptrs, ptrs.count, nil)
    let infos = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] ?? []
    return infos.compactMap { w in
        guard (w[kCGWindowIsOnscreen as String] as? Bool) == true,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return r
    }
}

// Rasterize on a coarse grid
let cell: CGFloat = 16
func cells(_ rects: [CGRect]) -> Set<Int> {
    var result = Set<Int>()
    for r in rects {
        var y = (r.minY / cell).rounded(.up) * cell
        while y < r.maxY {
            var x = (r.minX / cell).rounded(.up) * cell
            while x < r.maxX {
                result.insert(Int(x / cell) &* 100_000 &+ Int(y / cell))
                x += cell
            }
            y += cell
        }
    }
    return result
}

let before = cells(onscreenRects())
var pid: pid_t = 0
let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
var actions: posix_spawn_file_actions_t? = nil
posix_spawn_file_actions_init(&actions)
posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
let t0 = now()
posix_spawn(&pid, command[0], &actions, nil, argv, environ)
var samples: [(Double, Set<Int>)] = []
while now() - t0 < durationMs {
    samples.append((now() - t0, cells(onscreenRects())))
    usleep(500)
}
var status: Int32 = 0
waitpid(pid, &status, 0)
let after = samples.last?.1 ?? []
// The area that is covered both before and after the command must stay covered all the time
let mustStayCovered = before.intersection(after)
var maxUncovered = 0.0
var uncoveredMs = 0.0
var prevT = 0.0
for (t, covered) in samples {
    let uncovered = Double(mustStayCovered.subtracting(covered).count) / Double(max(1, mustStayCovered.count))
    maxUncovered = max(maxUncovered, uncovered)
    if uncovered > 0.005 { uncoveredMs += t - prevT }
    prevT = t
}
print(String(format: "desktop visible: max %.0f%% of the area, for %.1fms", maxUncovered * 100, uncoveredMs))
