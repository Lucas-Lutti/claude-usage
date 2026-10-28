import Foundation
import Security

/// Busca a porcentagem oficial da janela de 5h usando o login OAuth do Claude Code CLI,
/// se ele existir nesta máquina (Keychain "Claude Code-credentials" ou ~/.claude/.credentials.json).
/// O token nunca sai da máquina a não ser para api.anthropic.com.
actor OfficialUsageClient {
    enum FetchResult {
        case usage(OfficialUsage)
        case noLogin        // sem login do Claude Code CLI nesta máquina
        case failed         // rede, token expirado, resposta inesperada
    }

    private var cachedToken: String?
    private var lastTokenMiss: Date?
    private let tokenRetryInterval: TimeInterval = 300

    func fetch() async -> FetchResult {
        guard let token = cachedToken ?? loadToken() else { return .noLogin }
        cachedToken = token

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 401 { cachedToken = nil; return .failed }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let five = json["five_hour"] as? [String: Any],
              let util = (five["utilization"] as? NSNumber)?.doubleValue else { return .failed }

        let seven = json["seven_day"] as? [String: Any]
        return .usage(OfficialUsage(fiveHour: util,
                                    fiveHourReset: Self.date(five["resets_at"]),
                                    sevenDay: (seven?["utilization"] as? NSNumber)?.doubleValue,
                                    sevenDayReset: Self.date(seven?["resets_at"]),
                                    fetchedAt: Date()))
    }

    private func loadToken() -> String? {
        // Sem login: tenta de novo a cada 5 min, para notar quando a pessoa logar no CLI.
        if let miss = lastTokenMiss, Date().timeIntervalSince(miss) < tokenRetryInterval { return nil }
        let file = ClaudePaths.mainDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let t = Self.token(in: data) { return t }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let t = Self.token(in: data) {
            return t
        }
        lastTokenMiss = Date()   // não fica consultando o Keychain a cada atualização
        return nil
    }

    func reset() { lastTokenMiss = nil; cachedToken = nil }

    private static func token(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
