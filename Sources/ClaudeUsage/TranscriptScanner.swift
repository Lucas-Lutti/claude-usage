import Foundation

/// Lê os arquivos .jsonl do Claude Code de forma incremental
/// (só os bytes novos de cada arquivo a cada varredura).
final class TranscriptScanner: @unchecked Sendable {
    let queue = DispatchQueue(label: "claude-usage.scanner", qos: .utility)

    private var offsets: [String: UInt64] = [:]
    private var entries: [String: UsageEntry] = [:]
    private let retention: TimeInterval = 8 * 86400
    private let usageMarker = Data("\"usage\"".utf8)

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    // Arquivos recentes (caminho → projeto) e data de cada pasta de projeto na última olhada.
    private var recentFiles: [String: String] = [:]
    private var dirDates: [String: Date] = [:]
    private var lastFullScan = Date.distantPast
    private let fullScanInterval: TimeInterval = 120
    private let fileKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

    /// Deve ser chamado dentro de `queue`.
    func scan(now: Date = Date()) -> UsageSnapshot {
        let cutoff = now.addingTimeInterval(-retention)

        // A varredura completa (todos os arquivos, inclusive antigos) roda a cada 2 min. No meio tempo,
        // só pastas de projeto cuja data mudou (sessão nova cria arquivo) e os arquivos já recentes.
        let full = now.timeIntervalSince(lastFullScan) >= fullScanInterval
        if full {
            lastFullScan = now
            recentFiles = [:]
        }
        for root in ClaudePaths.projectRoots {
            for (dir, date) in projectDirs(in: root) where full || dirDates[dir.path] != date {
                dirDates[dir.path] = date
                collectRecent(in: dir, cutoff: cutoff)
            }
        }

        for (path, project) in recentFiles {
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: fileKeys), let size = v.fileSize else { continue }
            read(url, size: UInt64(size), fallbackProject: project)
        }

        entries = entries.filter { $0.value.timestamp >= cutoff }
        let sorted = entries.values.sorted { $0.timestamp < $1.timestamp }
        return UsageSnapshot(blocks: Block.build(from: sorted),
                             entries: sorted,
                             scannedAt: now,
                             filesTracked: offsets.count)
    }

    private func projectDirs(in root: URL) -> [(URL, Date?)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            return v?.isDirectory == true ? (url, v?.contentModificationDate) : nil
        }
    }

    /// Guarda os .jsonl modificados dentro do período de retenção (inclui subpastas de subagentes).
    private func collectRecent(in dir: URL, cutoff: Date) {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(fileKeys),
                                                      options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let mod = (try? url.resourceValues(forKeys: fileKeys))?.contentModificationDate,
                  mod >= cutoff else { continue }
            recentFiles[url.path] = dir.lastPathComponent
        }
    }

    private func read(_ url: URL, size: UInt64, fallbackProject: String) {
        let key = url.path
        var start = offsets[key] ?? 0
        if size < start { start = 0 }          // arquivo foi truncado/reescrito
        guard size > start,
              let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(),
              let lastNL = data.lastIndex(of: 0x0A) else { return }

        // Só consome até a última linha completa; o resto é lido na próxima vez.
        let complete = data[data.startIndex...lastNL]
        offsets[key] = start + UInt64(complete.count)

        for line in complete.split(separator: 0x0A) where line.range(of: usageMarker) != nil {
            parse(Data(line), fallbackProject: fallbackProject)
        }
    }

    private func parse(_ line: Data, fallbackProject: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { return }

        let model = msg["model"] as? String ?? "?"
        if model == "<synthetic>" { return }

        let tokens = Tokens(input: usage["input_tokens"] as? Int ?? 0,
                            output: usage["output_tokens"] as? Int ?? 0,
                            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
        if tokens.all == 0 { return }

        let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? fallbackProject
        // Respostas em streaming aparecem várias vezes com o mesmo id + requestId.
        let id = "\(msg["id"] as? String ?? obj["uuid"] as? String ?? ts):\(obj["requestId"] as? String ?? "")"
        entries[id] = UsageEntry(timestamp: date, model: model, project: project, tokens: tokens)
    }
}
