#if DEBUG && os(macOS)
import AppKit
import os

/// Debug-only timing log used by repeatable performance scenarios. It records
/// counts and durations, never article or library content.
@MainActor
public enum MainThreadLog {
    private static var lines: [String] = []
    private static let flushAt = 100
    nonisolated private static let signposter = OSSignposter(subsystem: "com.tim.nook", category: "perf")

    public static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ui-forensics.log")
    }

    public static func note(_ phase: String, extra: String = "") {
        lines.append(stamp() + " " + phase.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + extra)
        if lines.count >= flushAt { flush() }
    }

    private static func raw(_ text: String) {
        lines.append(stamp() + " " + text)
        if lines.count >= flushAt { flush() }
    }

    private static func stamp() -> String {
        String(ProcessInfo.processInfo.systemUptime.rounded(toPlaces: 3))
    }

    public static func runBegin() {
        guard !didBeginRun else { return }
        didBeginRun = true
        let arguments = ProcessInfo.processInfo.arguments
        let label = launchValue("-NookPerfLabel", in: arguments) ?? "debug"
        let library = launchValue("-NookPerfLibrary", in: arguments)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "default"
        let sha = launchValue("-NookPerfSHA", in: arguments)
            ?? ProcessInfo.processInfo.environment["NOOK_GIT_SHA"] ?? "unknown"
        let hz = NSScreen.main?.maximumFramesPerSecond ?? 0
        raw("run.begin label=\(token(label)) sha=\(token(sha)) lib=\(token(library)) hz=\(hz) log=\(url.path)")
        flush()
    }

    public static func scenarioBegin(id: String, rep: Int, cold: Bool) {
        if scenario != nil { scenarioEnd() }
        previousFrameTimestamp = nil
        scenario = Scenario(
            id: id, rep: rep, startedAt: ProcessInfo.processInfo.systemUptime,
            probe: MainThreadProbe.shared.snapshot(), frames: [], dropped: 0,
            hitchMs: 0, publishRows: 0, didRecordPublish: false, ttfr: 0)
        scenarioSignpostState = signposter.beginInterval("scenario", "id=\(id, privacy: .public)")
        note("scenario.begin", extra: "id=\(token(id)) rep=\(rep) cold=\(cold ? 1 : 0)")
    }

    public static func scenarioEnd() {
        guard let current = scenario else { return }
        scenario = nil
        if let state = scenarioSignpostState { signposter.endInterval("scenario", state) }
        scenarioSignpostState = nil

        let durationMs = (ProcessInfo.processInfo.systemUptime - current.startedAt) * 1000
        let diff = MainThreadProbe.shared.diff(since: current.probe)
        let stalls = diff.stalls.map { $0 * 1000 }
        let frames = current.frames.sorted()
        let p99Index = frames.isEmpty ? 0 : min(frames.count - 1, Int(Double(frames.count) * 0.99))
        let calls: (String) -> Int = { diff.samples[$0]?.count ?? 0 }
        let total: (String) -> Double = { diff.samples[$0]?.reduce(0, +) ?? 0 }
        let p95: (String) -> Double = { percentile(diff.samples[$0] ?? [], 0.95) }
        let maximum: (String) -> Double = { diff.samples[$0]?.max() ?? 0 }
        let fields = [
            "scenario.stats", "id=\(token(current.id))", "rep=\(current.rep)", "dur=\(number(durationMs))",
            "stalls50=\(stalls.filter { $0 >= 50 }.count)", "stalls100=\(stalls.filter { $0 >= 100 }.count)",
            "stalls250=\(stalls.filter { $0 >= 250 }.count)", "stalls500=\(stalls.filter { $0 >= 500 }.count)",
            "stalls1000=\(stalls.filter { $0 >= 1000 }.count)", "worstStall=\(number(stalls.max() ?? 0))",
            "stalledMs=\(number(stalls.reduce(0, +)))", "ttfr=\(number(current.ttfr))",
            "publish=\(calls("list.publish"))", "publishRows=\(current.publishRows)", "body=\(calls("list.body"))",
            "rowcontent=\(calls("list.rowcontent"))", "row=\(calls("list.row"))", "rowHeight=\(calls("list.row.height"))",
            "rowMenu=\(calls("list.row.menu") + calls("list.row.swipe"))", "relTime=\(calls("relativetime.body"))",
            "rootBody=\(calls("root.body"))", "sidebarBody=\(calls("sidebar.body"))", "sidebarRow=\(calls("sidebar.row"))",
            "readerBody=\(calls("reader.body"))", "frames=\(current.frames.count)", "dropped=\(current.dropped)",
            "hitchMs=\(number(current.hitchMs))", "hitchRatio=\(number(durationMs > 0 ? current.hitchMs / (durationMs / 1000) : 0))",
            "p99Frame=\(number(frames.isEmpty ? 0 : frames[p99Index]))", "worstFrame=\(number(frames.last ?? 0))",
            "applyMs=\(number(total("store.applyDisplayed")))", "mergeMs=\(number(p95("store.merge")))",
            "mergeFlush=\(calls("store.merge.flush"))", "mergeChangedNoNew=\(calls("store.merge.changedNoNew"))",
            "mergeFallback=\(calls("store.merge.fallback"))", "didsetMs=\(number(total("store.didset.articles")))",
            "markSeenMs=\(number(total("store.markSeen")))", "hlcTick=\(calls("store.hlc.tick"))",
            "updateInPlaceMs=\(number(total("store.updateInPlace")))", "grow=\(calls("list.window.grow"))",
            "growMaxMs=\(number(maximum("list.window.grow")))",
        ]
        raw(fields.joined(separator: " "))
        flush()
    }

    public static var isScenarioActive: Bool { scenario != nil }

    public static func recordFrame(timestamp: Double, targetTimestamp: Double) {
        guard var current = scenario else { return }
        defer { scenario = current }
        guard let previous = previousFrameTimestamp else {
            previousFrameTimestamp = timestamp
            return
        }
        previousFrameTimestamp = timestamp
        let delta = max(0, (timestamp - previous) * 1000)
        let expected = max(0.1, (targetTimestamp - timestamp) * 1000)
        current.frames.append(delta)
        if delta > expected * 1.5 {
            current.dropped += max(1, Int((delta / expected).rounded(.down)) - 1)
            current.hitchMs += max(0, delta - expected)
        }
    }

    public static func selectionBegan(source: String) {
        selectStartedAt = ProcessInfo.processInfo.systemUptime
        note("select.begin", extra: "source=\(token(source))")
    }

    public static func recordListPublish(from oldCount: Int, to newCount: Int, animated: Bool) {
        lastPublishAt = ProcessInfo.processInfo.systemUptime
        add("list.publish", ms: 0)
        if animated { add("list.publish.animated", ms: 0) }
        note("list.publish", extra: "rows=\(oldCount)->\(newCount) animated=\(animated)")
        if var current = scenario {
            if !current.didRecordPublish {
                current.publishRows = newCount
                current.didRecordPublish = true
            }
            scenario = current
        }
        if selectStartedAt != nil { pendingSettle = true }
    }

    private static func heartbeat(_ now: Double) {
        MainThreadProbe.shared.beat(now)
        guard pendingSettle, let selectedAt = selectStartedAt else { return }
        pendingSettle = false
        selectStartedAt = nil
        let ms = (now - selectedAt) * 1000
        if var current = scenario { current.ttfr = ms; scenario = current }
        note("list.settled", extra: "sinceSelect=\(number(ms))ms")
    }

    public static func noteFallbackTags(in html: String) {
        guard fallbacksLogged < 24 else { return }
        fallbacksLogged += 1
        var tags: Set<String> = []
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            let rest = html[html.index(after: open)...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "!" }
            if !name.isEmpty { tags.insert(name.lowercased()) }
            guard let next = html[html.index(after: open)...].firstIndex(of: "<") else { break }
            index = next
        }
        note("import.fallback", extra: "len=\(html.utf8.count) tags=\(tags.sorted().joined(separator: ","))")
    }

    private static var fallbacksLogged = 0

    @discardableResult
    public static func activity(_ label: String) -> String { MainThreadProbe.shared.setActivity(label) }

    @discardableResult
    nonisolated public static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let name = signpostName(label)
        let state = signposter.beginInterval(name)
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            MainThreadProbe.shared.add(label, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            signposter.endInterval(name, state)
        }
        return try work()
    }

    nonisolated public static func add(_ label: String, ms: Double) { MainThreadProbe.shared.add(label, ms: ms) }

    public static func summary() {
        let stalls = MainThreadProbe.shared.stallSummary()
        raw("SUMMARY  main thread stalled \(stalls.count) times, \(stalls.total.rounded(toPlaces: 2))s in total, worst \(stalls.worst.rounded(toPlaces: 2))s")
        for entry in MainThreadProbe.shared.totalsSnapshot() {
            let per = entry.calls > 0 ? entry.ms / Double(entry.calls) : 0
            raw("SUMMARY  " + entry.label.padding(toLength: 26, withPad: " ", startingAt: 0)
                + "\(entry.calls)".padding(toLength: 8, withPad: " ", startingAt: 0)
                + "calls  \(entry.ms.rounded(toPlaces: 1))ms total  \(per.rounded(toPlaces: 2))ms/call")
        }
    }

    public static func startWatchdog() {
        guard heartbeatTimer == nil else { return }
        runBegin()
        let configuredMs = launchValue("-NookStallMs", in: ProcessInfo.processInfo.arguments).flatMap(Double.init)
        let heartbeatInterval = configuredMs == nil ? 0.05 : 0.008
        let threshold = (configuredMs ?? 250) / 1000
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { _ in
            MainActor.assumeIsolated { MainThreadLog.heartbeat(ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        let writer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MainThreadLog.flush() }
        }
        RunLoop.main.add(writer, forMode: .common)
        flushTimer = writer

        let names: [(CFRunLoopActivity, String)] = [
            (.entry, "entry"), (.beforeTimers, "beforeTimers"), (.beforeSources, "beforeSources"),
            (.beforeWaiting, "beforeWaiting"), (.afterWaiting, "afterWaiting"), (.exit, "exit"),
        ]
        let phases = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            MainThreadProbe.shared.setPhase(names.first { $0.0 == activity }?.1 ?? "?")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), phases, .commonModes)
        phaseObserver = phases

        let watchdog = Thread {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if let stall = MainThreadProbe.shared.sample(now: now, threshold: threshold) {
                    Task { @MainActor in
                        MainThreadLog.note("STALL", extra: "for \(stall.seconds.rounded(toPlaces: 3))s during \(stall.during)")
                    }
                }
                Thread.sleep(forTimeInterval: heartbeatInterval)
            }
        }
        watchdog.name = "nook.ui-forensics.watchdog"
        watchdog.qualityOfService = .utility
        watchdog.start()
    }

    public static func flush() {
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        lines.removeAll()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    private struct Scenario {
        let id: String
        let rep: Int
        let startedAt: Double
        let probe: MainThreadProbe.Snapshot
        var frames: [Double]
        var dropped: Int
        var hitchMs: Double
        var publishRows: Int
        var didRecordPublish: Bool
        var ttfr: Double
    }

    private static var didBeginRun = false
    private static var scenario: Scenario?
    private static var scenarioSignpostState: OSSignpostIntervalState?
    private static var previousFrameTimestamp: Double?
    private static var selectStartedAt: Double?
    private static var pendingSettle = false
    public private(set) static var lastPublishAt: Double = 0
    private static var heartbeatTimer: Timer?
    private static var flushTimer: Timer?
    private static var phaseObserver: CFRunLoopObserver?

    public static var secondsSinceLastStall: Double {
        ProcessInfo.processInfo.systemUptime - MainThreadProbe.shared.lastStallAt()
    }

    private nonisolated static func signpostName(_ label: String) -> StaticString {
        switch label {
        case "store.applyDisplayed": "store.applyDisplayed"
        case "bg.filter": "bg.filter"
        case "store.merge": "store.merge"
        case "store.didset.articles": "store.didset.articles"
        case "store.markSeen": "store.markSeen"
        case "store.updateInPlace": "store.updateInPlace"
        case "root.body": "root.body"
        case "sidebar.body": "sidebar.body"
        case "sidebar.row": "sidebar.row"
        case "reader.body": "reader.body"
        default: "nook.perf"
        }
    }

    private static func launchValue(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func token(_ value: String) -> String { value.replacingOccurrences(of: " ", with: "_") }
    private static func number(_ value: Double) -> String { String(value.rounded(toPlaces: 2)) }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))]
    }
}

private final class MainThreadProbe: @unchecked Sendable {
    struct Snapshot: Sendable { let sampleCounts: [String: Int]; let stallCount: Int }
    static let shared = MainThreadProbe()
    private let lock = NSLock()
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var activity = "-"
    private var phase = "-"
    private var samples: [String: [Double]] = [:]
    private var stalls: [(started: Double, seconds: Double, during: String)] = []
    private var inStall: (started: Double, activity: String, phase: String, work: [String: Int])?
    private var lastStallEndedAt = -Double.infinity

    func beat(_ now: Double) { lock.withLock { heartbeat = now } }
    @discardableResult func setActivity(_ label: String) -> String {
        lock.withLock { let previous = activity; activity = label; return previous }
    }
    func setPhase(_ value: String) { lock.withLock { phase = value } }
    func add(_ label: String, ms: Double) { lock.withLock { samples[label, default: []].append(ms) } }
    func snapshot() -> Snapshot { lock.withLock { Snapshot(sampleCounts: samples.mapValues(\.count), stallCount: stalls.count) } }

    func diff(since snapshot: Snapshot) -> (samples: [String: [Double]], stalls: [Double]) {
        lock.withLock {
            var changed: [String: [Double]] = [:]
            for (label, values) in samples { changed[label] = Array(values.dropFirst(snapshot.sampleCounts[label] ?? 0)) }
            return (changed, Array(stalls.dropFirst(snapshot.stallCount)).map(\.seconds))
        }
    }

    func sample(now: Double, threshold: Double) -> (seconds: Double, during: String)? {
        let state = lock.withLock { (heartbeat, activity, phase, samples.mapValues(\.count)) }
        let late = now - state.0
        if late > threshold {
            if inStall == nil { inStall = (now - late, state.1, state.2, state.3) }
            return nil
        }
        guard let stall = inStall else { return nil }
        inStall = nil
        let seconds = now - stall.started
        let after = lock.withLock { samples }
        let ran = after.compactMap { label, values -> String? in
            let count = values.count - (stall.work[label] ?? 0)
            guard count > 0 else { return nil }
            let ms = values.suffix(count).reduce(0, +)
            return ms >= 1 ? "\(label)x\(count) \(ms.rounded(toPlaces: 0))ms" : "\(label)x\(count)"
        }.prefix(4).joined(separator: ", ")
        let during = (stall.activity == "-" ? "runloop:\(stall.phase)" : stall.activity)
            + (ran.isEmpty ? "  ran nothing counted" : "  ran \(ran)")
        lock.withLock { stalls.append((stall.started, seconds, during)) }
        lock.withLock { lastStallEndedAt = now }
        return (seconds, during)
    }

    func totalsSnapshot() -> [(label: String, calls: Int, ms: Double)] {
        lock.withLock {
            samples.map { (label: $0.key, calls: $0.value.count, ms: $0.value.reduce(0, +)) }.sorted { $0.ms > $1.ms }
        }
    }
    func stallSummary() -> (count: Int, total: Double, worst: Double) {
        lock.withLock { (stalls.count, stalls.reduce(0) { $0 + $1.seconds }, stalls.map(\.seconds).max() ?? 0) }
    }
    func lastStallAt() -> Double { lock.withLock { lastStallEndedAt } }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places)); return (self * factor).rounded() / factor
    }
}
#endif
