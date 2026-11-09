import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import WidgetKit

/// Ein überwachter Account. Metadaten liegen in `~/.claude-usage/accounts.json`, Tokens in der Keychain.
struct Account: Codable, Identifiable, Hashable {
    var id: String          // Slug, zugleich Ordnername unter ~/.claude-usage
    var name: String
    var email: String?
    var plan: String?
    var configDir: String
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: AccountUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var pendingLogin: String?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-usage")
    private static let accountsFile = baseDir.appendingPathComponent("accounts.json")
    private static let pollInterval: TimeInterval = 300
    private static let credentialPrefix = "Claude Code-credentials"

    private var timer: Timer?
    private var backoffUntil: [String: Date] = [:]

    init() {
        loadAccounts()
        if let snap = SnapshotStore.load() {
            for a in snap.accounts where accounts.contains(where: { $0.id == a.id }) { usage[a.id] = a }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15)) // Netzwerk nach dem Aufwachen abwarten
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    // MARK: - Anzeige

    var orderedUsage: [AccountUsage] { accounts.compactMap { usage[$0.id] ?? placeholder(for: $0) } }

    var menuBarTitle: String {
        orderedUsage.map { u in
            let pct = u.bindingPercent.map { "\(Int($0.rounded()))" } ?? (u.error != nil ? "!" : "–")
            return "\(u.shortName) \(pct)"
        }.joined(separator: " · ")
    }

    var lastUpdate: Date? { orderedUsage.compactMap(\.updatedAt).min() }

    private func placeholder(for a: Account) -> AccountUsage {
        AccountUsage(id: a.id, name: a.name, shortName: shortName(for: a), email: a.email, plan: a.plan)
    }

    /// Erster Buchstabe; bei Kollision die ersten zwei.
    private func shortName(for a: Account) -> String {
        let first = String(a.name.prefix(1)).uppercased()
        let clash = accounts.filter { $0.id != a.id && $0.name.prefix(1).uppercased() == first }
        return clash.isEmpty ? first : String(a.name.prefix(2)).capitalized
    }

    // MARK: - Abfrage

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let due = accounts.filter { force || (backoffUntil[$0.id] ?? .distantPast) <= now }
        let previous = usage
        let results = await withTaskGroup(of: (String, AccountUsage, Date?).self) { group in
            for a in due {
                let base = previous[a.id] ?? placeholder(for: a)
                let short = shortName(for: a)
                group.addTask { await Self.load(account: a, base: base, shortName: short) }
            }
            var out: [(String, AccountUsage, Date?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (id, u, backoff) in results {
            usage[id] = u
            backoffUntil[id] = backoff
        }
        publish()
    }

    nonisolated private static func load(account a: Account, base: AccountUsage, shortName: String) async -> (String, AccountUsage, Date?) {
        var u = base
        u.name = a.name
        u.shortName = shortName
        u.email = a.email
        u.plan = planName(configDir: a.configDir) ?? a.plan.map(\.capitalized)
        guard var tokens = TokenStore.load(a.id) else {
            u.error = "Kein Login gespeichert – neu anmelden"
            u.needsLogin = true
            return (a.id, u, nil)
        }
        do {
            if tokens.isExpiringSoon {
                tokens = try await ClaudeAPI.refresh(tokens)
                TokenStore.save(tokens, for: a.id)
            }
            let data: Data
            do {
                data = try await ClaudeAPI.fetchUsage(accessToken: tokens.accessToken)
            } catch ClaudeAPIError.unauthorized {
                tokens = try await ClaudeAPI.refresh(tokens)
                TokenStore.save(tokens, for: a.id)
                data = try await ClaudeAPI.fetchUsage(accessToken: tokens.accessToken)
            }
            let p = try UsageParser.parse(data)
            u.session = p.session
            u.weekly = p.weekly
            u.modelWeekly = p.modelWeekly
            u.extra = p.extra
            u.updatedAt = Date()
            u.error = nil
            u.needsLogin = nil
            return (a.id, u, nil)
        } catch ClaudeAPIError.rateLimited(let retryAfter) {
            let until = Date().addingTimeInterval(max(retryAfter ?? 600, 60))
            u.error = "Rate-Limit – nächster Versuch \(UsageFormat.reset(until))"
            return (a.id, u, until)
        } catch let e as ClaudeAPIError {
            if case .reloginRequired = e { u.needsLogin = true }
            u.error = e.localizedDescription
            return (a.id, u, nil)
        } catch {
            u.error = error.localizedDescription
            return (a.id, u, nil)
        }
    }

    /// Planname aus der Rate-Limit-Stufe in `<configDir>/.claude.json` (keine Secrets).
    /// Seit 30.10.2026: Max 20x → „Ultra“, Max 5x → „Max“.
    nonisolated private static func planName(configDir: String) -> String? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acc = root["oauthAccount"] as? [String: Any] else { return nil }
        let tier = ((acc["userRateLimitTier"] as? String) ?? (acc["organizationRateLimitTier"] as? String) ?? "").lowercased()
        if tier.contains("ultra") || tier.contains("max_20x") { return "Ultra" }
        if tier.contains("max") { return "Max" }
        if tier.contains("pro") { return "Pro" }
        return nil
    }

    private func publish() {
        SnapshotStore.save(UsageSnapshot(accounts: orderedUsage, generatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Accounts verwalten

    private func loadAccounts() {
        guard let data = try? Data(contentsOf: Self.accountsFile),
              let list = try? JSONDecoder().decode([Account].self, from: data) else { return }
        accounts = list
    }

    private func saveAccounts() {
        try? FileManager.default.createDirectory(at: Self.baseDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(accounts) { try? data.write(to: Self.accountsFile, options: .atomic) }
    }

    func addAccount() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude-Account hinzufügen"
        alert.informativeText = """
        Name für die Anzeige (z. B. „Privat“, „Firma“).

        Danach öffnet sich ein Terminal mit „claude auth login“ in einem eigenen Ordner. \
        Melde dich dort mit dem gewünschten Account an. Das ist ein separater Login nur für diese \
        Anzeige – Orca und dein normales Claude Code bleiben unberührt.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Weiter")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var slug = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "account" }
        var unique = slug, n = 2
        while accounts.contains(where: { $0.id == unique }) { unique = "\(slug)-\(n)"; n += 1 }

        startLogin(id: unique, name: name, dir: Self.baseDir.appendingPathComponent(unique), isNew: true)
    }

    /// Erneuert den Monitoring-Login eines bestehenden Accounts (z. B. nach verworfenem Refresh-Token).
    func relogin(_ id: String) {
        guard pendingLogin == nil, let a = accounts.first(where: { $0.id == id }) else { return }
        let dir = URL(fileURLWithPath: a.configDir)
        // Liegt bereits ein Login vor, der neuer ist als unser gespeicherter Token, direkt übernehmen.
        if let ours = Keychain.modificationDate(service: TokenStore.service, account: a.id),
           let tokens = findCredentials(dir: dir, servicesBefore: Keychain.services(prefix: Self.credentialPrefix),
                                        since: ours.addingTimeInterval(1)) {
            TokenStore.save(tokens, for: a.id)
            backoffUntil[a.id] = nil
            Task { await refresh(force: true) }
            return
        }
        startLogin(id: a.id, name: a.name, dir: dir, isNew: false)
    }

    private func startLogin(id: String, name: String, dir: URL, isNew: Bool) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("login.command")
            try """
            #!/bin/zsh -l
            export CLAUDE_CONFIG_DIR="\(dir.path)"
            CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
            echo "Login für Claude Usage – Account „\(name)“ (eigener Ordner: $CLAUDE_CONFIG_DIR)"
            echo
            "$CLAUDE_BIN" auth login --claudeai
            echo
            echo "Fertig. Claude Usage übernimmt den Login automatisch – dieses Fenster kann geschlossen werden."
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let before = Keychain.services(prefix: Self.credentialPrefix)
            // Sekundengenaue Keychain-Zeitstempel → 1 s Spielraum.
            let since = Date().addingTimeInterval(-1)
            pendingLogin = name
            NSWorkspace.shared.open(script)
            Task { await waitForLogin(id: id, name: name, dir: dir, isNew: isNew, servicesBefore: before, since: since) }
        } catch {
            showError("Konnte Login nicht vorbereiten: \(error.localizedDescription)")
        }
    }

    /// Wartet bis zu 15 min darauf, dass `claude auth login` die Credentials ablegt, und übernimmt sie.
    private func waitForLogin(id: String, name: String, dir: URL, isNew: Bool, servicesBefore: Set<String>, since: Date) async {
        defer { pendingLogin = nil }
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            guard pendingLogin == name else { return } // abgebrochen
            guard let tokens = findCredentials(dir: dir, servicesBefore: servicesBefore, since: since) else { continue }
            TokenStore.save(tokens, for: id)
            let info = await Self.authStatus(configDir: dir.path)
            if let i = accounts.firstIndex(where: { $0.id == id }) {
                accounts[i].email = info.email ?? accounts[i].email
                accounts[i].plan = info.plan ?? accounts[i].plan
            } else if isNew {
                accounts.append(Account(id: id, name: name, email: info.email, plan: info.plan, configDir: dir.path))
            } else {
                return // Account wurde während des Logins entfernt
            }
            saveAccounts()
            backoffUntil[id] = nil
            await refresh(force: true)
            return
        }
        showError("Kein Login für „\(name)“ gefunden (Zeitüberschreitung). Bitte erneut versuchen.")
    }

    func cancelPendingLogin() { pendingLogin = nil }

    /// Sucht die von `claude auth login` abgelegten Credentials. Nur Einträge, die seit `since` geschrieben
    /// wurden, zählen – ein alter Eintrag im selben Ordner enthält einen längst rotierten Refresh-Token.
    private func findCredentials(dir: URL, servicesBefore: Set<String>, since: Date) -> OAuthTokens? {
        // Claude Code legt bei eigenem CLAUDE_CONFIG_DIR einen eigenen Eintrag an:
        // "Claude Code-credentials-<erste 8 Hex-Zeichen von sha256(Pfad)>".
        let hash = SHA256.hash(data: Data(dir.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let expected = "\(Self.credentialPrefix)-\(hash.prefix(8))"
        var service: String?
        if Keychain.exists(service: expected) {
            service = expected
        } else {
            let new = Keychain.services(prefix: Self.credentialPrefix).subtracting(servicesBefore)
            if new.count == 1 { service = new.first }
        }
        if let service, let mdat = Keychain.modificationDate(service: service), mdat >= since,
           let data = Keychain.readViaSecurityTool(service: service), let t = OAuthTokens.fromClaudeCode(data) {
            return t
        }
        let file = dir.appendingPathComponent(".credentials.json")
        if let mdat = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           mdat >= since, let data = try? Data(contentsOf: file), let t = OAuthTokens.fromClaudeCode(data) { return t }
        return nil
    }

    nonisolated private static func authStatus(configDir: String) async -> (email: String?, plan: String?) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "\"$(command -v claude || echo $HOME/.local/bin/claude)\" auth status --json"]
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = configDir
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                cont.resume(returning: (obj?["email"] as? String, obj?["subscriptionType"] as? String))
            }
            do { try p.run() } catch { cont.resume(returning: (nil, nil)) }
        }
    }

    func remove(_ id: String) {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "„\(a.name)“ entfernen?"
        alert.informativeText = "Entfernt den Monitoring-Login aus Claude Usage. Orca und Claude Code sind nicht betroffen."
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TokenStore.delete(id)
        accounts.removeAll { $0.id == id }
        usage[id] = nil
        saveAccounts()
        publish()
    }

    func openOrca() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca")
            ?? URL(string: "file:///Applications/Orca.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError("Login-Objekt konnte nicht geändert werden: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func showError(_ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Usage"
        alert.informativeText = msg
        alert.runModal()
    }
}
