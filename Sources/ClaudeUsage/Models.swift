import Foundation

/// Tokens de uma ou mais respostas do Claude.
struct Tokens: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    func counted(includeCacheReads: Bool) -> Int {
        input + output + cacheWrite + (includeCacheReads ? cacheRead : 0)
    }

    var all: Int { input + output + cacheWrite + cacheRead }

    static func + (a: Tokens, b: Tokens) -> Tokens {
        Tokens(input: a.input + b.input,
               output: a.output + b.output,
               cacheWrite: a.cacheWrite + b.cacheWrite,
               cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout Tokens, b: Tokens) { a = a + b }
}

/// Uma resposta do assistente lida dos transcripts do Claude Code.
struct UsageEntry {
    let timestamp: Date
    let model: String
    let project: String
    let tokens: Tokens
}

/// Janela de 5 horas: começa na hora cheia da primeira mensagem e dura 5h.
struct Block {
    static let duration: TimeInterval = 5 * 3600

    let start: Date
    var end: Date { start.addingTimeInterval(Block.duration) }
    var entries: [UsageEntry] = []

    var lastActivity: Date { entries.last?.timestamp ?? start }
    var tokens: Tokens { entries.reduce(Tokens()) { $0 + $1.tokens } }

    func isActive(at now: Date) -> Bool {
        now < end && now.timeIntervalSince(lastActivity) < Block.duration
    }

    var byModel: [(model: String, tokens: Tokens)] {
        Dictionary(grouping: entries, by: \.model)
            .map { ($0.key, $0.value.reduce(Tokens()) { $0 + $1.tokens }) }
            .sorted { $0.1.all > $1.1.all }
    }

    var byProject: [(project: String, tokens: Tokens)] {
        Dictionary(grouping: entries, by: \.project)
            .map { ($0.key, $0.value.reduce(Tokens()) { $0 + $1.tokens }) }
            .sorted { $0.1.all > $1.1.all }
    }

    static func build(from sorted: [UsageEntry]) -> [Block] {
        var blocks: [Block] = []
        for e in sorted {
            if var current = blocks.last,
               e.timestamp < current.end,
               e.timestamp.timeIntervalSince(current.lastActivity) < duration {
                current.entries.append(e)
                blocks[blocks.count - 1] = current
            } else {
                blocks.append(Block(start: e.timestamp.floorToHour, entries: [e]))
            }
        }
        return blocks
    }
}

/// Resultado de uma varredura dos transcripts.
struct UsageSnapshot {
    var blocks: [Block] = []
    var entries: [UsageEntry] = []
    var scannedAt: Date = .distantPast
    var filesTracked = 0

    func activeBlock(at now: Date) -> Block? {
        guard let last = blocks.last, last.isActive(at: now) else { return nil }
        return last
    }

    func tokens(since date: Date) -> Tokens {
        entries.reduce(Tokens()) { $1.timestamp >= date ? $0 + $1.tokens : $0 }
    }
}

/// Uso oficial informado pela API do Claude (quando há login do Claude Code CLI).
struct OfficialUsage {
    var fiveHour: Double          // 0–100
    var fiveHourReset: Date?
    var sevenDay: Double?
    var sevenDayReset: Date?
    var fetchedAt: Date
}

extension Date {
    var floorToHour: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: self)) ?? self
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000...: return String(format: d >= 10_000_000 ? "%.0fM" : "%.1fM", d / 1_000_000)
        case 1_000...: return String(format: d >= 100_000 ? "%.0fk" : "%.1fk", d / 1_000)
        default: return "\(n)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
