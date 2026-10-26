import SwiftUI
import WidgetKit

// This file belongs to the "NookWidget" widget-extension target.
// Setup in Xcode:
//   • Add this file and Nook/WidgetShared.swift to the NookWidget target.
// No App Group is required: this is a quick-access launcher. Each shortcut
// deep-links into the app via the nook:// URL scheme, launching or
// activating Nook and focusing the chosen smart source.

struct NookEntry: TimelineEntry {
    let date: Date
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry { NookEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        completion(NookEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        completion(Timeline(entries: [NookEntry(date: .now)], policy: .never))
    }
}

// The @main WidgetBundle lives in the Xcode-generated NookWidgetBundle.swift,
// which references NookWidget().
struct NookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: NookProvider()) { _ in
            NookWidgetView()
                .containerBackground(.background, for: .widget)
                .widgetURL(WidgetShared.openAppURL)
        }
        .configurationDisplayName("Nook")
        .description("Quick access to your reader.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NookWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("Nook")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WidgetSource.allCases) { source in
                    Link(destination: WidgetShared.sourceURL(source)) {
                        shortcut(source)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func shortcut(_ source: WidgetSource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.systemImage)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(source.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Today News Widget

struct TodayNewsEntry: TimelineEntry {
    let date: Date
    let articles: [TodayNewsItem]
    var isPlaceholder: Bool = false
}

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
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }

    private static let placeholderItems: [TodayNewsItem] = (1...8).map { i in
        TodayNewsItem(
            id: "\(i)",
            title: "今日新闻标题示例将显示在这里 \(i)",
            url: URL(string: "https://example.com")!,
            feedTitle: "订阅源名称",
            publishedAt: .now
        )
    }
}

struct TodayNewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetShared.todayNewsWidgetKind,
            provider: TodayNewsProvider()
        ) { entry in
            TodayNewsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("今日新闻")
        .description("一览今天收到的文章标题。")
        .supportedFamilies([.systemLarge])
    }
}

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
        .widgetURL(WidgetShared.sourceURL(.today))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "newspaper.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            Text("今日新闻")
                .font(.headline)
            Spacer(minLength: 0)
            if !entry.articles.isEmpty {
                Text("\(entry.articles.count)条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("今天暂无新文章。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entry.articles) { item in
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
