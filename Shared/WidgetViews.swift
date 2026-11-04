import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    let family: WidgetFamily

    private var accounts: [AccountUsage] { Array((entry.snapshot?.accounts ?? []).prefix(family == .systemLarge ? 4 : 3)) }

    var body: some View {
        Group {
            if accounts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent").font(.title2)
                    Text("Claude Usage öffnen und Account hinzufügen").font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else {
                switch family {
                case .systemSmall: small
                case .systemLarge: large
                default: medium
                }
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { u in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(u.name).font(.caption.weight(.semibold)).lineLimit(1).emailBlur(u.name)
                        Spacer()
                        if u.error != nil && u.session == nil { Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                    }
                    HStack(spacing: 6) {
                        MiniStat(label: "5h", window: u.session, noLimit: u.hasNoSessionLimit)
                        MiniStat(label: "W", window: u.weekly)
                    }
                    if let r = u.session?.resetsAt, r > entry.date {
                        Text("Reset \(UsageFormat.reset(r, now: entry.date))").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { u in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.name).font(.caption.weight(.semibold)).lineLimit(1).emailBlur(u.name)
                        if let p = u.plan { Text(p.capitalized).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    .frame(width: 62, alignment: .leading)
                    WindowCell(window: u.session, fallback: "5 h", now: entry.date, noLimit: u.hasNoSessionLimit)
                    WindowCell(window: u.weekly, fallback: "Woche", now: entry.date)
                }
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(accounts) { u in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(u.name).font(.subheadline.weight(.semibold)).emailBlur(u.name)
                        if let p = u.plan { Text(p.capitalized).font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        if let err = u.error { Text(err).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1) }
                    }
                    HStack(spacing: 10) {
                        WindowCell(window: u.session, fallback: "5 h", now: entry.date, noLimit: u.hasNoSessionLimit)
                        WindowCell(window: u.weekly, fallback: "Woche", now: entry.date)
                    }
                    ForEach(u.modelWeekly, id: \.label) { w in
                        HStack {
                            Text(w.label).font(.system(size: 10))
                            UsageBar(percent: w.usedPercent, height: 3)
                            Text(UsageFormat.percent(w.usedPercent)).font(.system(size: 10)).monospacedDigit()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        Text("Stand: \(UsageFormat.ago(accounts.compactMap(\.updatedAt).min(), now: entry.date))")
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

private struct MiniStat: View {
    let label: String
    let window: UsageWindow?
    var noLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(noLimit ? "∞" : window.map { UsageFormat.percent($0.usedPercent) } ?? "–")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(window.map { UsageFormat.color($0.usedPercent) } ?? .secondary)
            }
            UsageBar(percent: window?.usedPercent ?? 0, height: 3).opacity(noLimit ? 0 : 1)
        }
    }
}

private struct WindowCell: View {
    let window: UsageWindow?
    let fallback: String
    let now: Date
    var noLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window?.label ?? fallback).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(noLimit ? "∞" : window.map { UsageFormat.percent($0.usedPercent) } ?? "–")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(window.map { UsageFormat.color($0.usedPercent) } ?? .secondary)
            }
            UsageBar(percent: window?.usedPercent ?? 0, height: 4).opacity(noLimit ? 0 : 1)
            Text(noLimit ? "kein 5-h-Limit" : window.map { $0.resetsAt == nil ? "ruht · startet bei Nutzung" : UsageFormat.reset($0.resetsAt, now: now) } ?? "–")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

extension UsageSnapshot {
    static var preview: UsageSnapshot {
        let now = Date()
        func acc(_ id: String, _ name: String, _ s: Double, _ w: Double) -> AccountUsage {
            AccountUsage(id: id, name: name, shortName: String(name.prefix(1)), plan: "Ultra",
                         session: UsageWindow(label: "5 h", usedPercent: s, resetsAt: now.addingTimeInterval(7800)),
                         weekly: UsageWindow(label: "Woche", usedPercent: w, resetsAt: now.addingTimeInterval(3 * 86400)),
                         updatedAt: now)
        }
        return UsageSnapshot(accounts: [acc("a", "Privat", 42, 18), acc("b", "Firma", 87, 64)], generatedAt: now)
    }
}
