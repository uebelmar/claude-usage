import Foundation
import Security

/// Dünne Hülle um die macOS-Keychain (Generic Passwords).
enum Keychain {
    /// Prüft nur, ob ein Eintrag existiert – liest keine Daten, löst also keinen Zugriffsdialog aus.
    static func exists(service: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// Liest einen von Claude Code angelegten Eintrag über `/usr/bin/security`. Claude Code schreibt seine
    /// Einträge mit diesem Tool, dessen ACL vertraut ihm also – kein Zugriffsdialog. Ein direktes
    /// `SecItemCopyMatching` würde dagegen nach jedem neuen Login erneut nach dem Passwort fragen,
    /// weil Claude Code den Eintrag neu anlegt und damit „Immer erlauben“ verwirft.
    static func readViaSecurityTool(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Letzte Änderung eines Eintrags (nur Attribute, kein Dialog).
    static func modificationDate(service: String, account: String? = nil) -> Date? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }

    /// Alle Service-Namen mit Präfix (nur Attribute, kein Dialog).
    static func services(prefix: String) -> Set<String> {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(prefix) })
    }

    static func read(service: String, account: String? = nil) -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(service: String, account: String, data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service) (\(account))"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
