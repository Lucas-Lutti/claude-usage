import Foundation
import UserNotifications

enum UsageSource { case official, local }

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var official: OfficialUsage?
    @Published private(set) var isScanning = false
    @Published private(set) var officialDenied = false

    let settings: Settings
    private let scanner = TranscriptScanner()
    private let api = OfficialUsageClient()
    private var lastOfficialFetch = Date.distantPast
    private var notifiedWindow: Date?

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
                let result = await api.fetch()
                // A opção pode ter sido desligada enquanto a consulta estava em andamento.
                guard self.settings.useOfficialAPI else { return }
                switch result {
                case .usage(let usage):
                    self.official = usage
                    self.checkNotification()
                case .noLogin: self.official = nil
                case .denied:
                    // Desliga a opção (fica salvo), para o macOS não pedir a senha a cada abertura do app.
                    self.official = nil
                    self.officialDenied = true
                    self.settings.useOfficialAPI = false
                case .failed:
                    // Mantém o último valor por até 10 min, para a % não alternar entre as fontes.
                    if let o = self.official, Date().timeIntervalSince(o.fetchedAt) > 600 { self.official = nil }
                }
            }
        } else if !settings.useOfficialAPI {
            official = nil
        }
    }

    /// Chamado ao ligar/desligar a % oficial. Ao ligar, libera uma nova tentativa de acesso ao Keychain.
    func officialOptionChanged() {
        guard settings.useOfficialAPI else { refresh(); return }
        officialDenied = false
        Task {
            await api.resetAccess()
            refresh(force: true)
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

    /// Uma notificação por janela. A janela é identificada pelo horário do reset, que existe tanto
    /// na % oficial (mesmo sem uso neste Mac) quanto na estimativa local.
    private func checkNotification() {
        guard settings.notify, let window = resetDate, window > now, notifiedWindow != window,
              usedFraction * 100 >= settings.criticalPercent else { return }
        notifiedWindow = window
        let used = Int((min(usedFraction, 1) * 100).rounded())
        let content = UNMutableNotificationContent()
        // Mesmo sentido do que aparece na barra (restante por padrão).
        content.title = settings.displayMode == .used
            ? "Claude: \(used)% da janela de 5h usados"
            : "Claude: restam \(100 - used)% da janela de 5h"
        content.body = "Reset às \(Fmt.time.string(from: window))."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "warn-\(window.timeIntervalSince1970)", content: content, trigger: nil))
    }
}
