import Foundation

/// Onde o Claude Code guarda configuração e transcripts.
enum ClaudePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let defaultDir = home.appendingPathComponent(".claude")

    /// Pastas de configuração. Apps abertos pelo Finder não herdam o ambiente do shell,
    /// então CLAUDE_CONFIG_DIR também é procurado no shell do usuário (resultado guardado por um dia).
    static let configDirs: [URL] = {
        let raw = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? cachedShellConfigDir()
        let custom = (raw ?? "").split(separator: ",").map {
            URL(fileURLWithPath: NSString(string: String($0)).expandingTildeInPath)
        }
        return custom.isEmpty ? [defaultDir] : custom
    }()

    /// Pasta principal (onde fica o settings.json usado pelo Claude Code).
    static var mainDir: URL { configDirs[0] }

    /// Pastas com transcripts .jsonl, sem repetição.
    static var projectRoots: [URL] {
        let all = configDirs + [defaultDir, home.appendingPathComponent(".config/claude")]
        var seen = Set<String>()
        return all.map { $0.appendingPathComponent("projects") }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Abrir o shell interativo executa o .zshrc inteiro, então só é feito uma vez por dia.
    private static func cachedShellConfigDir() -> String? {
        let defaults = UserDefaults.standard
        if let checked = defaults.object(forKey: "shellConfigDirCheckedAt") as? Date,
           Date().timeIntervalSince(checked) < 86400 {
            let value = defaults.string(forKey: "shellConfigDir") ?? ""
            return value.isEmpty ? nil : value
        }
        let value = shellVariable("CLAUDE_CONFIG_DIR")
        defaults.set(value ?? "", forKey: "shellConfigDir")
        defaults.set(Date(), forKey: "shellConfigDirCheckedAt")
        return value
    }

    /// Lê uma variável do shell interativo de login do usuário (com limite de 3 s).
    private static func shellVariable(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Marcadores separam o valor de qualquer texto que o .zshrc/.bashrc imprima.
        process.arguments = ["-ilc", "printf '__CU__%s__CU__' \"$\(name)\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }

        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let open = text.range(of: "__CU__"),
              let close = text.range(of: "__CU__", range: open.upperBound..<text.endIndex) else { return nil }
        let value = String(text[open.upperBound..<close.lowerBound])
        return value.isEmpty ? nil : value
    }
}
