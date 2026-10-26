import SwiftUI
import WidgetKit

// This file belongs to the "NookWidget" widget-extension target.
// It uses TodayNewsItem and WidgetShared from the shared Nook/WidgetShared.swift,
// which must be added to the NookWidget target's membership in Xcode.

// MARK: - Timeline entry

struct TodayNewsEntry: TimelineEntry {
    let date: Date
    let articles: [TodayNewsItem]

    /// True when the entry is a design-time placeholder (no real data).
    var isPlaceholder: Bool = false
}

// MARK: - Provider

struct TodayNewsProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayNewsEntry {
        TodayNewsEntry(date: .now, articles: Self.placeholderItems, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayNewsEntry) -> Void) {
        let items = WidgetShared.readTodayNews()
        let entry = TodayNewsEntry(
            date: .now,
            articles: (context.isPreview && items.isEmpty) ? Self.placeholderItems : items
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayNewsEntry>) -> Void) {
        let items = WidgetShared.readTodayNews()
        let entry = TodayNewsEntry(date: .now, articles: items)
        // Expire at midnight so stale "today" articles are cleared automatically
        // even if the app hasn't refreshed. The app also triggers a reload
        // explicitly after each successful fetch via WidgetCenter.
        let midnight = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(24 * 60 * 60)
        )
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }

    private static let placeholderItems: [TodayNewsItem] = (1...8).map { i in
        TodayNewsItem(
            id: "\(i)",
            title: "오늘의 뉴스 제목 예시가 여기에 표시됩니다 \(i)",
            url: URL(string: "https://example.com")!,
            feedTitle: "피드 이름",
            publishedAt: .now
        )
    }
}

// MARK: - Widget definition

struct TodayNewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetShared.todayNewsWidgetKind,
            provider: TodayNewsProvider()
        ) { entry in
            TodayNewsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("오늘의 뉴스")
        .description("오늘 도착한 기사 제목 목록을 한눈에 봅니다.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Widget view

private struct TodayNewsWidgetView: View {
    let entry: TodayNewsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6)
            if entry.articles.isEmpty {
                emptyState
            } else {
                articleList
            }
            Spacer(minLength: 0)
            footer
        }
        // Deep-link to the Today smart source when the widget background is tapped.
        .widgetURL(WidgetShared.sourceURL(.today))
    }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "newspaper.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            Text("오늘의 뉴스")
                .font(.headline)
            Spacer(minLength: 0)
            if !entry.articles.isEmpty {
                Text("\(entry.articles.count)개")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("오늘 도착한 기사가 없습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entry.articles) { item in
                // Each row is a Link — tapping it opens the article URL in the
                // default browser. WidgetKit routes Link taps to the system
                // browser on macOS when the destination is an https:// URL.
                Link(destination: item.url) {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(.tint.opacity(0.6))
                            .frame(width: 4, height: 4)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(entry.isPlaceholder ? .secondary : .primary)
                            Text(item.feedTitle)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if item.id != entry.articles.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "books.vertical.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Nook")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}
