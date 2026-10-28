import Foundation

/// Hook "SessionStart" no settings.json do Claude Code que abre este app
/// (em segundo plano) sempre que uma sessão do Claude Code começa.
enum ClaudeHook {
    static let bundleID = Bundle.main.bundleIdentifier ?? "local.claudeusage"
    /// A saída do hook vira contexto da sessão, por isso é descartada; `|| true` garante que nunca falhe.
    static var command: String { "open -g -b \(bundleID) >/dev/null 2>&1 || true" }

    static var claudeDir: URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           let first = env.split(separator: ",").first {
            return URL(fileURLWithPath: String(first))
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    /// Claude Code instalado/usado nesta máquina?
    static var claudeCodeFound: Bool { FileManager.default.fileExists(atPath: claudeDir.path) }

    static var isInstalled: Bool {
        guard let json = try? readSettings() else { return false }
        return sessionStartGroups(in: json).contains(where: isOurs)
    }

    static func install() throws {
        var json = try readSettings()
        var groups = sessionStartGroups(in: json).filter { !isOurs($0) }
        groups.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
        try write(groups, into: &json)
    }

    static func uninstall() throws {
        var json = try readSettings()
        let groups = sessionStartGroups(in: json).filter { !isOurs($0) }
        try write(groups, into: &json)
    }

    // MARK: - JSON

    enum HookError: LocalizedError {
        case invalidSettings
        var errorDescription: String? { "O settings.json do Claude Code não é um JSON válido; nada foi alterado." }
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.invalidSettings
        }
        return json
    }

    private static func sessionStartGroups(in json: [String: Any]) -> [[String: Any]] {
        ((json["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains("open -g -b \(bundleID)") == true
        }
    }

    private static func write(_ groups: [[String: Any]], into json: inout [String: Any]) throws {
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = groups.isEmpty ? nil : groups
        json["hooks"] = hooks.isEmpty ? nil : hooks

        let fm = FileManager.default
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        // Cópia de segurança do arquivo original antes da primeira alteração.
        let backup = claudeDir.appendingPathComponent("settings.json.claudeusage-backup")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
