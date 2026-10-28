import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let settings = Settings()
    lazy var store = UsageStore(settings: settings)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var timerInterval = 0
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageRight

        popover.behavior = .transient
        popover.delegate = self

        store.objectWillChange.merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
                self?.scheduleTimer()
            }
            .store(in: &cancellables)

        // A opção já vem ligada, então a permissão precisa ser pedida aqui (o macOS só pergunta uma vez).
        if settings.notify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

        updateButton()
        store.refresh(force: true)
        scheduleTimer()
    }

    private func scheduleTimer() {
        guard timerInterval != settings.refreshSeconds else { return }
        timerInterval = settings.refreshSeconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timerInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
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
