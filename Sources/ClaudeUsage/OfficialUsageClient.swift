import Foundation
import Security

/// Busca a porcentagem oficial da janela de 5h usando o login OAuth do Claude Code CLI,
/// se ele existir nesta máquina (Keychain "Claude Code-credentials" ou ~/.claude/.credentials.json).
/// O token nunca sai da máquina a não ser para api.anthropic.com.
/// Só é usado quando a pessoa liga a opção: ler o Keychain de outro app faz o macOS pedir a senha.
actor OfficialUsageClient {
    enum FetchResult {
        case usage(OfficialUsage)
        case noLogin        // sem login do Claude Code CLI nesta máquina
        case denied         // a pessoa negou (ou cancelou) o acesso ao Keychain
        case failed         // rede, token expirado, resposta inesperada
    }

    private var cachedToken: String?
    private var lastTokenMiss: Date?
    private var denied = false
    private var nextTokenRead: Date?
    private let tokenRetryInterval: TimeInterval = 300
    /// Depois de um 401, espera antes de reler o Keychain: o token só muda quando o Claude Code o renova,
    /// e cada leitura pode fazer o macOS pedir a senha (se não houver "Sempre Permitir").
    private let expiredRetryInterval: TimeInterval = 1800

    func fetch() async -> FetchResult {
        if denied { return .denied }
        if cachedToken == nil, let next = nextTokenRead, Date() < next { return .failed }
        guard let token = cachedToken ?? loadToken() else { return denied ? .denied : .noLogin }
        cachedToken = token

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 401 {
            cachedToken = nil
            nextTokenRead = Date().addingTimeInterval(expiredRetryInterval)
            return .failed
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
        // Sem janela ativa a API manda "five_hour": null — é 0% usado, não uma falha.
        let five = json["five_hour"] as? [String: Any]
        guard five != nil || json["five_hour"] is NSNull else { return .failed }

        let seven = json["seven_day"] as? [String: Any]
        return .usage(OfficialUsage(fiveHour: (five?["utilization"] as? NSNumber)?.doubleValue ?? 0,
                                    fiveHourReset: Self.date(five?["resets_at"]),
                                    sevenDay: (seven?["utilization"] as? NSNumber)?.doubleValue,
                                    sevenDayReset: Self.date(seven?["resets_at"]),
                                    fetchedAt: Date()))
    }

    private func loadToken() -> String? {
        // Sem login: tenta de novo a cada 5 min, para notar quando a pessoa logar no CLI.
        // (Item inexistente não gera pedido de senha; só um item existente sem permissão gera.)
        if let miss = lastTokenMiss, Date().timeIntervalSince(miss) < tokenRetryInterval { return nil }
        if let next = nextTokenRead, Date() < next { return nil }
        let file = ClaudePaths.mainDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let t = Self.token(in: data) { return t }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            if let data = out as? Data, let t = Self.token(in: data) { return t }
            lastTokenMiss = Date()
        case errSecItemNotFound:
            lastTokenMiss = Date()   // não fica consultando o Keychain a cada atualização
        default:
            denied = true            // negado/cancelado: não pede a senha de novo sozinho
        }
        return nil
    }

    /// Volta a tentar o Keychain (ao religar a opção).
    func resetAccess() { denied = false; lastTokenMiss = nil; nextTokenRead = nil; cachedToken = nil }

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
