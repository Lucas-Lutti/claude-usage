import Foundation
import Security

/// Busca a porcentagem oficial da janela de 5h usando o login OAuth do Claude Code CLI,
/// se ele existir nesta máquina (Keychain "Claude Code-credentials" ou ~/.claude/.credentials.json).
/// O token nunca sai da máquina a não ser para api.anthropic.com.
/// Só é usado quando a pessoa liga a opção: ler o Keychain de outro app faz o macOS pedir a senha.
actor OfficialUsageClient {
    enum FetchResult {
        case usage(OfficialUsage)
        case noLogin        // sem login do Claude Code nesta máquina
        case denied         // a pessoa negou (ou cancelou) o acesso ao Keychain
        case expired        // o login venceu e o Claude Code ainda não renovou
        case failed         // rede, resposta inesperada
    }

    /// Token de acesso e quando ele vence (campo `expiresAt` salvo pelo Claude Code).
    private struct Credential {
        let token: String
        let expiresAt: Date?
        var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
    }

    private var credential: Credential?
    private var lastTokenMiss: Date?
    private var denied = false
    private let tokenRetryInterval: TimeInterval = 300

    func fetch() async -> FetchResult {
        if denied { return .denied }
        // Passado o vencimento, relê o Keychain na hora: se o Claude Code já renovou, segue sem avisar.
        if credential?.isExpired == true { credential = nil }
        if credential == nil {
            guard let loaded = loadCredential() else { return denied ? .denied : .noLogin }
            credential = loaded
        }
        guard let current = credential, !current.isExpired else {
            credential = nil
            return .expired
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(current.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 401 {
            credential = nil
            return .expired
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

    private func loadCredential() -> Credential? {
        // Sem login: tenta de novo a cada 5 min, para notar quando a pessoa logar no Claude Code.
        // (Item inexistente não gera pedido de senha; só um item existente sem permissão gera.)
        if let miss = lastTokenMiss, Date().timeIntervalSince(miss) < tokenRetryInterval { return nil }
        let file = ClaudePaths.mainDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let c = Self.credential(in: data) { return c }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            if let data = out as? Data, let c = Self.credential(in: data) { return c }
            lastTokenMiss = Date()
        case errSecItemNotFound:
            lastTokenMiss = Date()   // não fica consultando o Keychain a cada atualização
        default:
            denied = true            // negado/cancelado: não pede a senha de novo sozinho
        }
        return nil
    }

    /// Volta a tentar o Keychain (ao religar a opção ou quando a pessoa diz que renovou o login).
    func resetAccess() { denied = false; lastTokenMiss = nil; credential = nil }

    private static func credential(in data: Data) -> Credential? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let oauth = json?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        // expiresAt vem em milissegundos desde 1970.
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credential(token: token, expiresAt: expires)
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
