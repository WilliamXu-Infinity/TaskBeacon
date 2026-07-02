import Foundation

// MARK: - Usage log model + aggregation
//
// The status hook appends one JSONL line per counted event to
// ~/.claude/taskbeacon/events.jsonl. This file turns that raw log into everything
// the stats window shows — headline counts, wall-clock time, token tallies, an
// estimated dollar cost, plus streak / peak-hours / heatmap views — sliced by a
// time range (today / week / month / all) and grouped by day, project, model, or
// individual task.

// One line in events.jsonl.
struct UsageEvent: Decodable {
    let ts: Int          // epoch seconds
    let date: String     // local "YYYY-MM-DD" as the hook saw it (the key for day buckets)
    let event: String    // "run" | "decision" | "done"
    let project: String  // basename of the session's cwd
    let title: String?   // the prompt summary, present on "run" events only
    let tty: String?     // controlling terminal — pairs a "run" with its "done"

    // Per-turn token tallies, present on "done" events only (the hook reads the
    // transcript at Stop). Optional: older log lines and any turn whose transcript
    // wasn't readable simply omit them.
    let tok_in: Int?        // fresh (non-cached) input tokens
    let tok_out: Int?       // generated tokens
    let tok_cache_w: Int?   // tokens written to cache (billed ~1.25x)
    let tok_cache_r: Int?   // tokens read from cache (billed ~0.1x, grows per API call)
    let api_calls: Int?     // assistant messages in the turn = API round-trips
    let model: String?      // the turn's model id (e.g. "claude-opus-4-8") — drives cost
}

// MARK: - Cost model (ESTIMATED)
//
// token → USD. Rates are per million tokens (MTok), 2026 list prices. Cache write
// is billed ~1.25x input (the 5-minute tier; Claude Code also uses a 1h tier at
// ~2x that this log can't distinguish, so writes may be under-counted) and cache
// read ~0.1x input. A turn with no recorded model is estimated as Sonnet. Every
// number this produces is an ESTIMATE, not a bill — surface it as such.
enum Pricing {
    struct Rate { let inp, out, cacheW, cacheR: Double }

    static func rate(for model: String?) -> Rate {
        let m = (model ?? "").lowercased()
        if m.contains("opus")  { return Rate(inp: 5, out: 25, cacheW: 6.25, cacheR: 0.50) }
        if m.contains("haiku") { return Rate(inp: 1, out: 5,  cacheW: 1.25, cacheR: 0.10) }
        return Rate(inp: 3, out: 15, cacheW: 3.75, cacheR: 0.30)   // sonnet / unknown
    }

    static func cost(inp: Int, out: Int, cacheW: Int, cacheR: Int, model: String?) -> Double {
        let r = rate(for: model)
        return (Double(inp) * r.inp + Double(out) * r.out
              + Double(cacheW) * r.cacheW + Double(cacheR) * r.cacheR) / 1_000_000
    }

    // "claude-opus-4-8" -> "Opus", etc. The by-model breakdown key.
    static func displayName(_ model: String?) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("opus")  { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        return "未知"
    }
}

// MARK: - Time range

enum TimeRange: Int, CaseIterable {
    case today, week, month, all

    var label: String {
        switch self {
        case .today: return "今日"
        case .week:  return "本周"
        case .month: return "本月"
        case .all:   return "全部"
        }
    }

    // Inclusive lower-bound epoch; an event passes when ts >= it. `all` is 0.
    // Week starts Monday, month on the 1st, both in the local calendar.
    func lowerBound(now: Date = Date()) -> Int {
        var cal = Calendar.current
        cal.firstWeekday = 2   // Monday
        switch self {
        case .all:   return 0
        case .today: return Int(cal.startOfDay(for: now).timeIntervalSince1970)
        case .week:
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return Int((cal.date(from: c) ?? now).timeIntervalSince1970)
        case .month:
            let c = cal.dateComponents([.year, .month], from: now)
            return Int((cal.date(from: c) ?? now).timeIntervalSince1970)
        }
    }
}

// MARK: - Buckets

// A rolled-up bucket for one day / project / model.
struct StatBucket {
    let key: String
    var runs = 0         // task runs (prompts submitted)
    var decisions = 0    // permission / plan / question confirmations
    var done = 0         // turns completed
    var total: Int { runs + decisions }   // activity weight, for busiest-first sorting

    // Token sums across this bucket's done events.
    var tokIn = 0, tokOut = 0, tokCacheW = 0, tokCacheR = 0
    var costUSD = 0.0    // estimated, summed per done event at its model's rate
    // Wall-clock time, summed over paired run->done tasks, plus the pair count so the
    // window can show both a total and an average.
    var durSec = 0
    var pairedTasks = 0

    // Cache read as a share of all input the model saw. High = good prompt reuse.
    var cacheHitRate: Double {
        let denom = tokIn + tokCacheR
        return denom > 0 ? Double(tokCacheR) / Double(denom) : 0
    }
}

// One run->done task, for the "by task" breakdown.
struct TaskRun {
    let ts: Int          // done ts (sort key, newest first)
    let title: String    // the run's prompt summary, or project name as a fallback
    let project: String
    let durSec: Int
    let tokIn, tokOut, tokCacheW, tokCacheR: Int
    let costUSD: Double
    let model: String?
}

// MARK: - Store

// Reads and aggregates the append-only event log. Cheap enough to re-parse on
// every window open — one short line per turn, and the window isn't hot.
final class StatsStore {
    static let logPath = "\(NSHomeDirectory())/.claude/taskbeacon/events.jsonl"

    private(set) var events: [UsageEvent] = []

    func reload() { events = Self.parse(Self.logPath) }

    static func parse(_ path: String) -> [UsageEvent] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        var out: [UsageEvent] = []
        // Skip any malformed line rather than dropping the whole log — a half-written
        // final line (crash mid-append) must not blank the whole window.
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let ev = try? dec.decode(UsageEvent.self, from: data) else { continue }
            out.append(ev)
        }
        return out
    }

    // Events whose ts falls in the range, ascending by ts.
    private func filtered(_ r: TimeRange) -> [UsageEvent] {
        let lb = r.lowerBound()
        let base = lb == 0 ? events : events.filter { $0.ts >= lb }
        return base.sorted { $0.ts < $1.ts }
    }

    // MARK: Range-scoped rollups

    // Headline totals for the range: one bucket, everything keyed the same.
    func totals(_ r: TimeRange) -> StatBucket {
        aggregate(filtered(r)) { _ in "*" }.first ?? StatBucket(key: "*")
    }

    // Days, newest first.
    func byDay(_ r: TimeRange) -> [StatBucket] {
        aggregate(filtered(r)) { $0.date }.sorted { $0.key > $1.key }
    }

    // Projects, busiest first (runs+decisions), name as the tiebreak.
    func byProject(_ r: TimeRange) -> [StatBucket] {
        aggregate(filtered(r)) { $0.project }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.key < $1.key }
    }

    // Models, priciest first. Only done events carry a model, so key off those —
    // runs/decisions have no model and would all pile under "未知".
    func byModel(_ r: TimeRange) -> [StatBucket] {
        let dones = filtered(r).filter { $0.event == "done" }
        return aggregate(dones) { Pricing.displayName($0.model) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    // Individual tasks (run->done pairs), newest first.
    func sessions(_ r: TimeRange) -> [TaskRun] {
        var open: [String: UsageEvent] = [:]   // tty -> the run in flight
        var out: [TaskRun] = []
        for e in filtered(r) {
            switch e.event {
            case "run":
                if let tty = e.tty { open[tty] = e }
            case "done":
                let ti = e.tok_in ?? 0, to = e.tok_out ?? 0
                let cw = e.tok_cache_w ?? 0, cr = e.tok_cache_r ?? 0
                let run = e.tty.flatMap { open[$0] }
                var dur = 0
                if let start = run?.ts { let d = e.ts - start; if d >= 0 && d < 24 * 3600 { dur = d } }
                let raw = (run?.title ?? e.title ?? "")
                let title = raw.isEmpty ? e.project : raw
                out.append(TaskRun(
                    ts: e.ts, title: title, project: e.project, durSec: dur,
                    tokIn: ti, tokOut: to, tokCacheW: cw, tokCacheR: cr,
                    costUSD: Pricing.cost(inp: ti, out: to, cacheW: cw, cacheR: cr, model: e.model),
                    model: e.model))
                if let tty = e.tty { open[tty] = nil }
            default: break
            }
        }
        return out.sorted { $0.ts > $1.ts }
    }

    // 24 buckets of activity (any event) by local hour, for the peak-hours bar.
    func peakHours(_ r: TimeRange) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        let cal = Calendar.current
        for e in filtered(r) {
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(e.ts)))
            if h >= 0 && h < 24 { buckets[h] += 1 }
        }
        return buckets
    }

    // MARK: Global (range-independent) views

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // Current streak (consecutive active days ending today or yesterday) and the
    // longest run ever. Days come from the `date` field, deduped.
    func streak() -> (current: Int, longest: Int) {
        let days = Set(events.map { $0.date }).compactMap { Self.df.date(from: $0) }.sorted()
        guard !days.isEmpty else { return (0, 0) }
        let cal = Calendar.current

        var longest = 1, run = 1
        if days.count > 1 {
            for i in 1..<days.count {
                let diff = cal.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 0
                run = diff == 1 ? run + 1 : 1
                longest = max(longest, run)
            }
        }

        // Current: only "live" if the most recent active day is today or yesterday.
        var current = 0
        if let last = days.last,
           let gap = cal.dateComponents([.day], from: last, to: Date()).day, gap <= 1 {
            current = 1
            var i = days.count - 1
            while i > 0 {
                let diff = cal.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 0
                if diff == 1 { current += 1; i -= 1 } else { break }
            }
        }
        return (current, longest)
    }

    // Activity count per day for the last `days` days, oldest first — the heatmap grid.
    func heatmap(days n: Int) -> [(date: Date, count: Int)] {
        var counts: [String: Int] = [:]
        for e in events { counts[e.date, default: 0] += 1 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [(Date, Int)] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            out.append((d, counts[Self.df.string(from: d)] ?? 0))
        }
        return out
    }

    // MARK: Core aggregation

    // One ordered pass builds every bucket. Counts, token sums and cost are per-event;
    // task duration needs pairing: a "run" opens a task on its tty, the next "done" on
    // that same tty closes it (done.ts - run.ts). A task is attributed to the bucket its
    // "done" lands in — so its tokens, cost and duration always agree.
    private func aggregate(_ events: [UsageEvent], _ keyOf: (UsageEvent) -> String) -> [StatBucket] {
        var map: [String: StatBucket] = [:]
        var openRun: [String: Int] = [:]   // tty -> run.ts of the task in flight
        for e in events {
            let k = keyOf(e)
            var b = map[k] ?? StatBucket(key: k)
            switch e.event {
            case "run":
                b.runs += 1
                if let tty = e.tty { openRun[tty] = e.ts }
            case "decision":
                b.decisions += 1
            case "done":
                b.done += 1
                let ti = e.tok_in ?? 0, to = e.tok_out ?? 0
                let cw = e.tok_cache_w ?? 0, cr = e.tok_cache_r ?? 0
                b.tokIn += ti; b.tokOut += to; b.tokCacheW += cw; b.tokCacheR += cr
                b.costUSD += Pricing.cost(inp: ti, out: to, cacheW: cw, cacheR: cr, model: e.model)
                if let tty = e.tty, let start = openRun[tty] {
                    let dur = e.ts - start
                    if dur >= 0 && dur < 24 * 3600 { b.durSec += dur; b.pairedTasks += 1 }
                    openRun[tty] = nil
                }
            default:
                break
            }
            map[k] = b
        }
        return Array(map.values)
    }
}
