import SwiftUI
import WidgetKit

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: context.isPreview ? (SnapshotStore.load() ?? .preview) : SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // Daten holt die Menüleisten-App und stößt danach ein Reload an.
        // Einträge alle 5 min, damit die Reset-Texte mitlaufen.
        let snap = SnapshotStore.load()
        let now = Date()
        let entries = (0..<6).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        UsageWidgetView(entry: entry, family: family)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsageWidget", provider: UsageProvider()) { entry in
            WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Auslastung und Reset-Zeiten deiner Claude-Abos.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

