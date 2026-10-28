import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let settings = Settings()
    lazy var store = UsageStore(settings: settings)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var timerInterval = 0
    private var cancellables = Set<AnyCancellable>()
    /// Claude (app desktop ou Claude Code) aberto agora.
    private var claudeOpen = true
    /// A pessoa abriu o app na mão com o Claude fechado: mostra o ícone até o Claude fechar de novo.
    private var shownByUser = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageRight

        popover.behavior = .transient
        popover.delegate = self
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(forName: .showUsagePanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPanel() }
        }
        // Abrir/fechar o app desktop do Claude é avisado na hora; o Claude Code é conferido a cada atualização.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClaudeState() }
            }
        }

        store.objectWillChange.merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
                self?.updateVisibility()
                self?.scheduleTimer()
            }
            .store(in: &cancellables)

        if settings.onboarded {
            // A opção já vem ligada, então a permissão é confirmada a cada abertura (o macOS só pergunta uma vez).
            if settings.notify {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            // Primeira abertura: mostra as boas-vindas antes de qualquer pedido do sistema.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.togglePopover() }
        }

        // Na primeira execução, passa a abrir junto com o Claude Code (dá para desligar em Personalizar).
        // Fora da thread principal: descobrir a pasta do Claude pode consultar o shell do usuário.
        // Só marca como feito se der certo; com settings.json inválido, tenta de novo na próxima abertura.
        if !settings.hookSetupDone {
            DispatchQueue.global(qos: .utility).async {
                let ok = ClaudeHook.claudeCodeFound && (try? ClaudeHook.install()) != nil
                if ok { DispatchQueue.main.async { self.settings.hookSetupDone = true } }
            }
        }

        // Para aparecer quando o Claude abrir, o app precisa já estar rodando: liga "Abrir ao iniciar sessão" uma vez.
        if settings.followClaude, !settings.followClaudeLoginDone {
            try? SMAppService.mainApp.register()
            settings.followClaudeLoginDone = true
        }

        claudeOpen = ClaudeProcess.isRunning
        updateVisibility()
        updateButton()
        store.refresh(force: true)
        scheduleTimer()
    }

    // Abrir o app de novo (Finder, Spotlight) com o Claude fechado mostra o ícone, sem abrir o painel:
    // o hook do Claude Code também "reabre" o app a cada sessão nova, e isso não pode abrir o menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !claudeOpen { shownByUser = true }
        updateVisibility()
        return false
    }

    private func showPanel() {
        shownByUser = !claudeOpen
        updateVisibility()
        if !popover.isShown { togglePopover() }
    }

    private func updateClaudeState() {
        let open = ClaudeProcess.isRunning
        if open && !claudeOpen { store.refresh(force: true) }   // acabou de abrir: atualiza na hora
        if !open && claudeOpen { shownByUser = false }
        claudeOpen = open
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = !settings.followClaude || !settings.onboarded || claudeOpen || shownByUser
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
        if !visible, popover.isShown { popover.performClose(nil) }
    }

    private func scheduleTimer() {
        guard timerInterval != settings.refreshSeconds else { return }
        timerInterval = settings.refreshSeconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timerInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateClaudeState()
                // Escondido (Claude fechado), não lê transcripts nem consulta a API.
                if self.statusItem.isVisible { self.store.refresh() }
            }
        }
        // Folga de 10% para o macOS agrupar este despertar com outros (economiza bateria).
        timer?.tolerance = TimeInterval(timerInterval) * 0.1
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            // O painel só existe enquanto está aberto, para não ficar redesenhando em segundo plano.
            let host = NSHostingController(rootView: PopoverView()
                .environmentObject(store)
                .environmentObject(settings))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // Clicar numa notificação abre o painel (ex.: aviso de login vencido).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .showUsagePanel, object: nil) }
        completionHandler()
    }

    // Mostra a notificação mesmo com o app ativo (ele não tem janela, então quase sempre está "ativo").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let used = store.usedFraction
        let pct = used * 100
        let level = settings.level(usedPercent: pct)
        let tint: NSColor? = settings.colorful || level != .ok ? level.nsColor : nil

        let text: String
        switch settings.displayMode {
        case .used: text = "\(Int(pct.rounded()))%"
        case .remaining: text = "\(max(0, Int((100 - pct).rounded())))%"
        case .tokens: text = Fmt.tokens(store.countedTokens)
        case .timeLeft:
            text = store.resetDate.map { Fmt.duration($0.timeIntervalSinceNow) } ?? "5h"
        }

        // Só no modo "% usado" o ícone enche; nos outros ele esvazia de 100% até 0%.
        let fill = settings.displayMode == .used ? used : 1 - used
        let icon = StatusIcon.image(style: settings.iconStyle, fill: fill, tint: tint)
        button.image = icon
        button.attributedTitle = settings.showText || icon == nil
            ? NSAttributedString(string: text + (icon != nil ? " " : ""),
                                 attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)])
            : NSAttributedString(string: "")
        button.toolTip = "Claude — \(Int(pct.rounded()))% da janela de 5h"
    }
}

// `ClaudeUsage --dump` imprime a janela atual no terminal (útil para conferir os números).
if CommandLine.arguments.contains("--dump") {
    let snap = TranscriptScanner().scan()
    let now = Date()
    print("arquivos: \(snap.filesTracked)  respostas (8 dias): \(snap.entries.count)  janelas: \(snap.blocks.count)")
    if let b = snap.activeBlock(at: now) {
        let t = b.tokens
        print("janela ativa: \(Fmt.time.string(from: b.start))–\(Fmt.time.string(from: b.end))  reset em \(Fmt.duration(b.end.timeIntervalSince(now)))")
        print("entrada \(t.input)  saída \(t.output)  cache escrita \(t.cacheWrite)  cache leitura \(t.cacheRead)  msgs \(b.entries.count)")
        for p in b.byProject { print("  \(p.project): \(Fmt.tokens(p.tokens.counted(includeCacheReads: false)))") }
    } else {
        print("nenhuma janela ativa")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
