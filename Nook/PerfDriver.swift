#if DEBUG
import AppKit
import NookKit

/// JSON schema:
/// ```json
/// {
///   "repetitions": 5,
///   "coldFirst": true,
///   "steps": [{
///     "id": "A1",
///     "setup": [{"type":"selectFeed","target":"feed-small"}],
///     "action": {"type":"selectSmart","target":"all"}
///   }]
/// }
/// ```
/// `type` is one of selectSmart/selectFeed/selectFeeds/selectFolder/
/// selectCategory/search/refreshAll/refreshFeed/refreshActivation/selectIndex/
/// setRead/toggleStar/nextArticle/fling/thumbDrag/constantScroll/keyRepeat/
/// classifyAll/wait/noop. Optional action fields are `target`, `ids`, `value`,
/// `index`, `count`, `rate`, and `duration` (seconds).
@MainActor
final class PerfDriver {
    static let shared = PerfDriver()
    private var didRun = false

    private struct Script: Decodable {
        var repetitions: Int?
        var coldFirst: Bool?
        let steps: [Step]
    }

    private struct Step: Decodable {
        let id: String
        var repetitions: Int?
        var coldFirst: Bool?
        var setup: [Action]?
        let action: Action
    }

    private struct Action: Decodable {
        let type: String
        var target: String?
        var ids: [String]?
        var value: String?
        var index: Int?
        var count: Int?
        var rate: Double?
        var duration: Double?
    }

    func runIfRequested(store: ReaderStore) async {
        guard !didRun, let path = launchValue("-NookPerfScript") else { return }
        didRun = true
        do {
            let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            fixWindowSize()
            let adapter = PerfStoreAdapter(store: store)
            for step in script.steps {
                let repetitions = max(1, step.repetitions ?? script.repetitions ?? 5)
                let includesCold = step.coldFirst ?? script.coldFirst ?? false
                if includesCold {
                    try await run(step: step, rep: 0, cold: true, adapter: adapter)
                }
                for rep in 1...repetitions {
                    try await run(step: step, rep: rep, cold: false, adapter: adapter)
                }
            }
        } catch {
            MainThreadLog.note("perf.driver.error", extra: "message=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))")
        }
        MainThreadLog.flush()
        NSApp.terminate(nil)
    }

    private func run(step: Step, rep: Int, cold: Bool, adapter: PerfStoreAdapter) async throws {
        for action in step.setup ?? [] { try await perform(action, adapter: adapter) }
        try await settle(adapter: adapter)
        MainThreadLog.scenarioBegin(id: step.id, rep: rep, cold: cold)
        try await perform(step.action, adapter: adapter)
        try await quiesce(adapter: adapter)
        MainThreadLog.scenarioEnd()
    }

    private func settle(adapter: PerfStoreAdapter) async throws {
        var stableSince = ProcessInfo.processInfo.systemUptime
        let deadline = stableSince + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let stable = !adapter.isRefreshing && MainThreadLog.secondsSinceLastStall >= 2
            if stable {
                if ProcessInfo.processInfo.systemUptime - stableSince >= 2 { return }
            } else {
                stableSince = ProcessInfo.processInfo.systemUptime
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func quiesce(adapter: PerfStoreAdapter) async throws {
        var stableSince = ProcessInfo.processInfo.systemUptime
        let deadline = stableSince + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            if adapter.isRefreshing {
                stableSince = now
            } else if MainThreadLog.lastPublishAt > stableSince {
                stableSince = MainThreadLog.lastPublishAt
            } else if now - stableSince >= 1.5 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func perform(_ action: Action, adapter: PerfStoreAdapter) async throws {
        switch action.type {
        case "selectSmart": adapter.selectSmart(action.target ?? "all")
        case "selectFeed": adapter.selectFeeds([action.target ?? "feed-small"])
        case "selectFeeds": adapter.selectFeeds(action.ids ?? [])
        case "selectFolder": adapter.selectFolder(action.target ?? "Folder 01")
        case "selectCategory": adapter.selectCategory(action.target ?? "1")
        case "search": adapter.setSearch(action.value ?? "")
        case "refreshAll": adapter.refreshAll()
        case "refreshFeed": adapter.refreshFeed(action.target ?? "feed-big")
        case "refreshActivation": adapter.refreshActivation()
        case "selectIndex": adapter.selectArticle(index: action.index ?? 0)
        case "setRead": adapter.setSelectedRead((action.value ?? "true") != "false")
        case "toggleStar": adapter.toggleSelectedStar()
        case "nextArticle": adapter.nextArticle()
        case "latestWins":
            adapter.selectSmart("all")
            try await Task.sleep(for: .milliseconds(100))
            adapter.selectSmart("unread")
        case "searchToggle":
            adapter.setSearch(action.value ?? "performance")
            try await Task.sleep(for: .milliseconds(500))
            adapter.setSearch("")
        case "toggleRead":
            for _ in 0..<(action.count ?? 20) {
                adapter.toggleSelectedRead()
                try await Task.sleep(for: .seconds(1 / max(1, action.rate ?? 2)))
            }
        case "toggleStarRepeat":
            for _ in 0..<(action.count ?? 20) {
                adapter.toggleSelectedStar()
                try await Task.sleep(for: .seconds(1 / max(1, action.rate ?? 2)))
            }
        case "nextRepeat":
            for _ in 0..<(action.count ?? 20) { adapter.nextArticle(); try await Task.sleep(for: .milliseconds(100)) }
        case "refreshAndFling": adapter.refreshAll(); try await fling(count: action.count ?? 8)
        case "fling": try await fling(count: action.count ?? 8)
        case "thumbDrag": try await thumbDrag(steps: action.count ?? 30, duration: action.duration ?? 1)
        case "constantScroll": try await constantScroll(rate: action.rate ?? 1500, duration: action.duration ?? 5)
        case "keyRepeat": try await keyRepeat(command: action.target == "commandDown", rate: action.rate ?? 30, duration: action.duration ?? 5)
        case "classifyAll": adapter.classifyAll()
        case "wait": try await Task.sleep(for: .seconds(action.duration ?? 1))
        case "noop": break
        default: MainThreadLog.note("perf.action.unknown", extra: "type=\(action.type)")
        }
    }

    private func fling(count: Int) async throws {
        guard let scrollView = PerfListScrollTarget.scrollView else { return }
        for _ in 0..<count {
            var velocity = 6_000.0
            while velocity > 40 {
                move(scrollView, by: velocity / displayHz)
                velocity *= 0.95
                try await nextFrame()
            }
        }
    }

    private func thumbDrag(steps: Int, duration: Double) async throws {
        guard let scrollView = PerfListScrollTarget.scrollView else { return }
        let maxY = scrollLimit(scrollView)
        for step in 1...max(1, steps) {
            move(scrollView, to: maxY * Double(step) / Double(max(1, steps)))
            try await Task.sleep(for: .seconds(duration / Double(max(1, steps))))
        }
        scrollView.scrollToEndOfDocument(nil)
    }

    private func constantScroll(rate: Double, duration: Double) async throws {
        guard let scrollView = PerfListScrollTarget.scrollView else { return }
        let frames = Int(duration * displayHz)
        for _ in 0..<max(1, frames) { move(scrollView, by: rate / displayHz); try await nextFrame() }
    }

    private func keyRepeat(command: Bool, rate: Double, duration: Double) async throws {
        let repeats = Int(rate * duration)
        for _ in 0..<max(1, repeats) {
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: true, keyCode: 125
            ) { NSApp.postEvent(event, atStart: false) }
            try await Task.sleep(for: .seconds(1 / max(1, rate)))
        }
    }

    private var displayHz: Double { Double(NSScreen.main?.maximumFramesPerSecond ?? 60) }
    private func nextFrame() async throws { try await Task.sleep(for: .seconds(1 / displayHz)) }
    private func scrollLimit(_ scrollView: NSScrollView) -> Double {
        max(0, Double((scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height))
    }
    private func move(_ scrollView: NSScrollView, by delta: Double) {
        move(scrollView, to: Double(scrollView.contentView.bounds.origin.y) + delta)
    }
    private func move(_ scrollView: NSScrollView, to y: Double) {
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: min(max(0, y), scrollLimit(scrollView)))
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func fixWindowSize() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else { return }
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func launchValue(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
private struct PerfStoreAdapter {
    let store: ReaderStore
    var isRefreshing: Bool { store.isRefreshing }

    func selectSmart(_ raw: String) {
        if let source = SmartSource(rawValue: raw) { store.selectSmartSource(source) }
    }
    func selectFeeds(_ targets: [String]) {
        let ids = targets.flatMap(resolveFeedTarget)
        store.feedSelection = Set(ids)
    }
    func selectFolder(_ target: String) { store.selectFolder(resolveIndexed(target, prefix: "Folder ", count: 12)) }
    func selectCategory(_ target: String) {
        let index = max(0, (Int(target.replacingOccurrences(of: "category-", with: "")) ?? 1) - 1)
        if store.categories.indices.contains(index) { store.selectCategory(store.categories[index].id) }
    }
    func setSearch(_ value: String) { store.searchText = value; store.debounceSearch() }
    func refreshAll() { store.refreshAll() }
    func refreshFeed(_ target: String) { resolveFeedTarget(target).first.map(store.refresh(feedID:)) }
    func refreshActivation() { store.refreshOnActivation(honorThrottle: false) }
    func selectArticle(index: Int) {
        guard store.visibleArticles.indices.contains(index) else { return }
        store.selectedArticleID = store.visibleArticles[index].id
    }
    func setSelectedRead(_ value: Bool) { store.selectedArticleID.map { store.setRead(articleID: $0, isRead: value) } }
    func toggleSelectedRead() {
        guard let id = store.selectedArticleID, let article = store.article(withID: id) else { return }
        store.setRead(articleID: id, isRead: !article.isRead)
    }
    func toggleSelectedStar() { store.selectedArticleID.map(store.toggleStarred(articleID:)) }
    func nextArticle() { store.selectNextArticle() }
    func classifyAll() { store.classifyAllExisting(provider: .appleIntelligence) }

    private func resolveFeedTarget(_ target: String) -> [Feed.ID] {
        switch target {
        case "feed-small": return ["perf-feed-small"]
        case "feed-big": return ["perf-feed-big"]
        case "all": return store.feeds.map(\.id)
        default:
            if target.hasPrefix("first:"), let count = Int(target.dropFirst(6)) { return Array(store.feeds.prefix(count).map(\.id)) }
            return [target]
        }
    }
    private func resolveIndexed(_ target: String, prefix: String, count: Int) -> String {
        if target.hasPrefix(prefix) { return target }
        let index = min(max(Int(target) ?? 1, 1), count)
        return prefix + String(format: "%02d", index)
    }
}
#endif
