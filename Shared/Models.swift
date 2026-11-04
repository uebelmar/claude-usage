import Foundation
import SwiftUI

/// Ein Limit-Fenster (5 h, Woche, Modell-Woche) mit Auslastung und Reset-Zeitpunkt.
struct UsageWindow: Codable, Hashable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
}

struct ExtraUsage: Codable, Hashable {
    var enabled: Bool
    var spent: Double?
    var limit: Double?
    var currency: String
    var usedPercent: Double?
}

/// Stand eines Accounts – wird von der App geschrieben und vom Widget gelesen. Keine Secrets.
struct AccountUsage: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var shortName: String
    var email: String?
    var plan: String?
    var session: UsageWindow?
    var weekly: UsageWindow?
    var modelWeekly: [UsageWindow] = []
    var extra: ExtraUsage?
    var updatedAt: Date?
    var error: String?
}

extension AccountUsage {
    /// Kein `five_hour` in der Antwort = Konto hat kein 5-h-Limit (verifiziertes Ultra seit 30.10.2026).
    /// Ein ruhendes 5-h-Fenster kommt dagegen als Objekt mit 0 % und ohne `resets_at`.
    var hasNoSessionLimit: Bool { session == nil && updatedAt != nil }

    /// Engstes Limit (höchste Auslastung aus 5 h und Woche) – Wert für die Menüleiste.
    var bindingPercent: Double? { [session?.usedPercent, weekly?.usedPercent].compactMap { $0 }.max() }
}

struct UsageSnapshot: Codable {
    var accounts: [AccountUsage]
    var generatedAt: Date
}

enum AppGroup {
    static var id: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "G33B89LJ73.claudeusage"
    }
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}

enum SnapshotStore {
    static var url: URL? { AppGroup.containerURL?.appendingPathComponent("snapshot.json") }

    static func load() -> UsageSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum UsageFormat {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func color(_ value: Double) -> Color {
        switch value {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// „in 2 h 13 min · 14:30“ (unter 24 h) bzw. „Mo., 09:00“.
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "–" }
        let secs = date.timeIntervalSince(now)
        if secs <= 0 { return "jetzt" }
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
        if secs < 24 * 3600 {
            let h = Int(secs) / 3600
            let m = (Int(secs) % 3600) / 60
            let rel = h > 0 ? "in \(h) h \(m) min" : "in \(max(m, 1)) min"
            return "\(rel) · \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "de_DE")))
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "nie" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "gerade eben" }
        if secs < 3600 { return "vor \(secs / 60) min" }
        return "vor \(secs / 3600) h"
    }

    static func money(_ value: Double?, _ currency: String) -> String {
        guard let value else { return "–" }
        return value.formatted(.currency(code: currency).locale(Locale(identifier: "de_DE")))
    }
}

/// Fortschrittsbalken, den Menüleiste und Widget teilen.
struct UsageBar: View {
    var percent: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(UsageFormat.color(percent))
                    .frame(width: max(height, geo.size.width * min(max(percent, 0), 100) / 100))
            }
        }
        .frame(height: height)
    }
}
