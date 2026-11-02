import Foundation

/// OAuth-Tokens eines Monitoring-Logins. Liegen ausschließlich im eigenen Keychain-Eintrag (Service `ClaudeUsage`).
struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 120
    }

    /// Format von Claude Code: `{"claudeAiOauth":{"accessToken":…,"refreshToken":…,"expiresAt":<ms>}}`
    static func fromClaudeCode(_ data: Data) -> OAuthTokens? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let access = o["accessToken"] as? String, !access.isEmpty else { return nil }
        var expires: Date?
        if let ms = o["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms > 1e10 ? ms / 1000 : ms) }
        return OAuthTokens(accessToken: access, refreshToken: o["refreshToken"] as? String, expiresAt: expires)
    }
}

enum TokenStore {
    static let service = "ClaudeUsage"

    static func load(_ accountID: String) -> OAuthTokens? {
        guard let data = Keychain.read(service: service, account: accountID) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func save(_ tokens: OAuthTokens, for accountID: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        Keychain.write(service: service, account: accountID, data: data)
    }

    static func delete(_ accountID: String) { Keychain.delete(service: service, account: accountID) }
}

enum ClaudeAPIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case reloginRequired(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token ungültig"
        case .rateLimited: return "Rate-Limit der Usage-Abfrage"
        case .reloginRequired(let msg): return "Login abgelaufen – neu anmelden (\(msg))"
        case .http(let code, let msg): return "HTTP \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        }
    }
}

enum ClaudeAPI {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Öffentliche OAuth-Client-ID von Claude Code (der Login wurde über `claude auth login` erzeugt).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    static func fetchUsage(accessToken: String) async throws -> Data {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-menubar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: return data
        case 401: throw ClaudeAPIError.unauthorized
        case 429:
            let ra = http?.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw ClaudeAPIError.rateLimited(retryAfter: ra)
        case let code: throw ClaudeAPIError.http(code, errorMessage(data))
        }
    }

    /// Erneuert den eigenen Monitoring-Login. Nie für Logins von Orca/Claude Code verwenden
    /// (Refresh-Token-Rotation würde diese abmelden).
    static func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw ClaudeAPIError.reloginRequired("kein Refresh-Token") }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 { throw ClaudeAPIError.reloginRequired(errorMessage(data)) }
        if code == 429 { throw ClaudeAPIError.rateLimited(retryAfter: nil) }
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw ClaudeAPIError.http(code, errorMessage(data))
        }
        let expiresIn = obj["expires_in"] as? Double
        return OAuthTokens(
            accessToken: access,
            refreshToken: (obj["refresh_token"] as? String) ?? refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let d = obj["error_description"] as? String { return d }
        if let e = obj["error"] as? String { return e }
        return ""
    }
}

/// Parst die (undokumentierte) Usage-Antwort defensiv – jedes Feld ist optional.
enum UsageParser {
    struct Parsed {
        var session: UsageWindow?
        var weekly: UsageWindow?
        var modelWeekly: [UsageWindow] = []
        var extra: ExtraUsage?
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.http(200, "unerwartetes Antwortformat")
        }
        var p = Parsed()
        p.session = window(root["five_hour"], label: "5 h")
        p.weekly = window(root["seven_day"], label: "Woche")

        var seen = Set<String>()
        // Neueres Format: limits[] mit kind == weekly_scoped
        if let limits = root["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                let scope = l["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                guard let name = model?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let pct = number(l["percent"]) else { continue }
                if seen.insert(name.lowercased()).inserted {
                    p.modelWeekly.append(UsageWindow(label: "Woche \(name)", usedPercent: clamp(pct), resetsAt: date(l["resets_at"])))
                }
            }
        }
        // Älteres Format: seven_day_<modell>
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") {
            let name = String(key.dropFirst("seven_day_".count))
            guard ["opus", "sonnet", "fable", "haiku"].contains(name), seen.insert(name).inserted,
                  let w = window(root[key], label: "Woche \(name.capitalized)") else { continue }
            p.modelWeekly.append(w)
        }

        if let e = root["extra_usage"] as? [String: Any] {
            let decimals = Int(number(e["decimal_places"]) ?? 2)
            let div = pow(10.0, Double(decimals))
            let limit = number(e["monthly_limit"]).map { $0 / div }
            let spent = number(e["used_credits"]).map { $0 / div }
            var pct = number(e["utilization"])
            if let limit, let spent, limit > 0 { pct = spent / limit * 100 }
            p.extra = ExtraUsage(
                enabled: (e["is_enabled"] as? Bool) ?? false,
                spent: spent, limit: limit,
                currency: ((e["currency"] as? String)?.isEmpty == false ? e["currency"] as! String : "USD"),
                usedPercent: pct.map(clamp)
            )
        }
        return p
    }

    private static func window(_ any: Any?, label: String) -> UsageWindow? {
        guard let o = any as? [String: Any],
              let pct = number(o["utilization"]) ?? number(o["used_percentage"]) else { return nil }
        return UsageWindow(label: label, usedPercent: clamp(pct), resetsAt: date(o["resets_at"]))
    }

    private static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func date(_ any: Any?) -> Date? {
        if let n = number(any), !(any is String) { return Date(timeIntervalSince1970: n > 1e10 ? n / 1000 : n) }
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Mikrosekunden (".123456") kann ISO8601DateFormatter nicht – Nachkommastellen entfernen.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: trimmed)
    }
}
