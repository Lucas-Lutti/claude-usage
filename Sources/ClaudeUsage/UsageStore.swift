import Foundation
import UserNotifications

enum UsageSource { case official, local }

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var official: OfficialUsage?
    @Published private(set) var isScanning = false

    let settings: Settings
    private let scanner = TranscriptScanner()
    private let api = OfficialUsageClient()
    private var lastOfficialFetch = Date.distantPast
    private var notifiedBlock: Date?

    init(settings: Settings) { self.settings = settings }

    /// Carrega dados prontos (usado pelo gerador de imagens em marketing/).
    func load(_ snapshot: UsageSnapshot, official: OfficialUsage? = nil) {
        self.snapshot = snapshot
        self.official = official
    }

    // MARK: Atualização

    func refresh(force: Bool = false) {
        if !isScanning {
            isScanning = true
            let scanner = scanner
            scanner.queue.async {
                let snap = scanner.scan()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.snapshot = snap
                    self.isScanning = false
                    self.checkNotification()
                }
            }
        }

        if settings.useOfficialAPI,
           force || Date().timeIntervalSince(lastOfficialFetch) >= 60 {
            lastOfficialFetch = Date()
            Task {
                if force { await api.reset() }
                switch await api.fetch() {
                case .usage(let usage): self.official = usage
                case .noLogin: self.official = nil
                case .failed:
                    // Mantém o último valor por até 10 min, para a % não alternar entre as fontes.
                    if let o = self.official, Date().timeIntervalSince(o.fetchedAt) > 600 { self.official = nil }
                }
            }
        } else if !settings.useOfficialAPI {
            official = nil
        }
    }

    // MARK: Valores derivados

    var now: Date { Date() }
    var activeBlock: Block? { snapshot.activeBlock(at: now) }

    var source: UsageSource {
        settings.useOfficialAPI && official != nil ? .official : .local
    }

    var countedTokens: Int {
        activeBlock?.tokens.counted(includeCacheReads: settings.includeCacheReads) ?? 0
    }

    /// Maior janela de 5h dos últimos dias (para o modo automático).
    var autoLimit: Int {
        let best = snapshot.blocks
            .map { $0.tokens.counted(includeCacheReads: settings.includeCacheReads) }
            .max() ?? 0
        return max(best, 100_000)
    }

    var limit: Int {
        switch settings.limitPreset {
        case .auto: autoLimit
        case .custom: max(settings.customLimit, 1)
        default: settings.limitPreset.tokens ?? 1
        }
    }

    /// 0…1 (pode passar de 1 no modo local).
    var usedFraction: Double {
        if source == .official, let o = official { return o.fiveHour / 100 }
        return Double(countedTokens) / Double(limit)
    }

    var resetDate: Date? {
        if source == .official, let r = official?.fiveHourReset { return r }
        return activeBlock?.end
    }

    /// Tokens por minuto desde o início da atividade na janela atual.
    var burnRate: Double? {
        guard let b = activeBlock, let first = b.entries.first?.timestamp else { return nil }
        let minutes = max(now.timeIntervalSince(first) / 60, 1)
        return Double(b.tokens.counted(includeCacheReads: settings.includeCacheReads)) / minutes
    }

    /// Projeção de tokens ao final da janela mantendo o ritmo atual.
    var projectedTokens: Int? {
        guard let b = activeBlock, let rate = burnRate else { return nil }
        let left = max(b.end.timeIntervalSince(now) / 60, 0)
        return countedTokens + Int(rate * left)
    }

    var todayTokens: Tokens { snapshot.tokens(since: Calendar.current.startOfDay(for: now)) }
    var weekTokens: Tokens { snapshot.tokens(since: now.addingTimeInterval(-7 * 86400)) }

    /// Tokens em fatias de 15 min dentro da janela atual (ou das últimas 5h).
    var timeline: [(start: Date, tokens: Int)] {
        let start = activeBlock?.start ?? now.addingTimeInterval(-Block.duration).floorToHour
        let slot: TimeInterval = 15 * 60
        var buckets = Array(repeating: 0, count: Int(Block.duration / slot))
        for e in snapshot.entries where e.timestamp >= start {
            let i = Int(e.timestamp.timeIntervalSince(start) / slot)
            if i >= 0 && i < buckets.count {
                buckets[i] += e.tokens.counted(includeCacheReads: settings.includeCacheReads)
            }
        }
        return buckets.enumerated().map { (start.addingTimeInterval(Double($0.offset) * slot), $0.element) }
    }

    // MARK: Notificações

    private func checkNotification() {
        guard settings.notify, let b = activeBlock, notifiedBlock != b.start,
              usedFraction * 100 >= settings.criticalPercent else { return }
        notifiedBlock = b.start
        let content = UNMutableNotificationContent()
        content.title = "Claude: \(Int(usedFraction * 100))% da janela de 5h"
        if let r = resetDate { content.body = "Reset às \(Fmt.time.string(from: r))." }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "warn-\(b.start)", content: content, trigger: nil))
    }
}
