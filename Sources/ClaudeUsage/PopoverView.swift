import SwiftUI
import Charts
import ServiceManagement
import UserNotifications

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: Settings
    @State private var tab: Int

    init(initialTab: Int = 0) { _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Uso").tag(0)
                Text("Personalizar").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == 0 { UsageTab() } else { SettingsTab() }

            Divider()
            HStack {
                Text("Atualizado \(Fmt.time.string(from: store.snapshot.scannedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Atualizar agora")
                Button("Sair") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Aba Uso

private struct UsageTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: Settings

    /// Contagem regressiva (100% → 0%) em todos os modos exceto "% usado".
    var descending: Bool { settings.displayMode != .used }
    var shown: Double {
        let used = min(max(store.usedFraction, 0), 1)
        return descending ? 1 - used : used
    }

    var tint: Color {
        let level = settings.level(usedPercent: store.usedFraction * 100)
        return settings.colorful || level != .ok ? level.color : .accentColor
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                header(now: ctx.date)
                tokenGrid
                chart
                if let o = store.official { officialSection(o) }
                if let b = store.activeBlock, b.byProject.count > 1 { projects(b) }
                totals
            }
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Janela de 5h").font(.headline)
                Spacer()
                Text(store.source == .official ? "API oficial" : "Estimativa local")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(descending ? "restante" : "usado").foregroundStyle(.secondary)
                Spacer()
                if store.source == .local {
                    Text(descending
                         ? "\(Fmt.tokens(max(store.limit - store.countedTokens, 0))) de \(Fmt.tokens(store.limit))"
                         : "\(Fmt.tokens(store.countedTokens)) / \(Fmt.tokens(store.limit))")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LevelBar(value: shown, color: tint)
            if let reset = store.resetDate, reset > now {
                Text("Reset em \(Fmt.duration(reset.timeIntervalSince(now))) · às \(Fmt.time.string(from: reset))")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Nenhuma janela ativa — a próxima mensagem inicia uma nova.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var tokenGrid: some View {
        let t = store.activeBlock?.tokens ?? Tokens()
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { stat("Entrada", t.input); stat("Saída", t.output) }
            GridRow {
                stat("Cache (escrita)", t.cacheWrite)
                stat("Cache (leitura)", t.cacheRead, dim: !settings.includeCacheReads)
            }
            GridRow {
                if let r = store.burnRate {
                    statText("Ritmo", "\(Fmt.tokens(Int(r)))/min")
                } else { statText("Ritmo", "—") }
                if let p = store.projectedTokens, store.source == .local {
                    let used = min(Int(Double(p) / Double(store.limit) * 100), 100)
                    statText(descending ? "Restará no reset" : "Projeção no reset", "\(descending ? 100 - used : used)%")
                } else { statText("Mensagens", "\(store.activeBlock?.entries.count ?? 0)") }
            }
        }
    }

    private func stat(_ label: String, _ n: Int, dim: Bool = false) -> some View {
        statText(label, Fmt.tokens(n)).opacity(dim ? 0.5 : 1)
    }

    private func statText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        Chart(store.timeline, id: \.start) { item in
            BarMark(x: .value("Hora", item.start, unit: .minute),
                    y: .value("Tokens", item.tokens), width: 9)
                .foregroundStyle(tint.gradient)
                .cornerRadius(2)
        }
        .chartYAxis { AxisMarks(position: .trailing) { v in
            AxisGridLine()
            AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)) } }
        } }
        .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in
            AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
        } }
        .frame(height: 90)
    }

    private func officialSection(_ o: OfficialUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Limites oficiais").font(.subheadline.weight(.semibold))
            limitRow("5 horas", o.fiveHour, o.fiveHourReset)
            if let s = o.sevenDay { limitRow("7 dias", s, o.sevenDayReset) }
        }
    }

    private func limitRow(_ label: String, _ pct: Double, _ reset: Date?) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            LevelBar(value: min(pct / 100, 1), color: .accentColor, height: 6)
            Text("\(Int(pct))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .font(.callout)
        .help(reset.map { "Reset: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }

    private func projects(_ b: Block) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Por projeto").font(.subheadline.weight(.semibold))
            ForEach(b.byProject.prefix(4), id: \.project) { p in
                HStack {
                    Text(p.project).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.tokens(p.tokens.counted(includeCacheReads: settings.includeCacheReads)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
    }

    private var totals: some View {
        HStack {
            statText("Hoje", Fmt.tokens(store.todayTokens.counted(includeCacheReads: settings.includeCacheReads)))
            statText("Últimos 7 dias", Fmt.tokens(store.weekTokens.counted(includeCacheReads: settings.includeCacheReads)))
            if let model = store.activeBlock?.byModel.first?.model {
                statText("Modelo", model.replacingOccurrences(of: "claude-", with: ""))
            }
        }
    }
}

// MARK: - Aba Personalizar

private struct SettingsTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: Settings
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    @State private var loginError: String?
    @State private var openWithClaude = ClaudeHook.isInstalled
    @State private var hookError: String?

    var body: some View {
        Form {
            Section("Barra de menus") {
                Picker("Mostrar", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                IconStylePicker(selection: $settings.iconStyle, descending: settings.displayMode != .used,
                                tint: settings.colorful ? .systemGreen : nil)
                Toggle("Ícone colorido (verde → laranja → vermelho)", isOn: $settings.colorful)
                Toggle("Mostrar porcentagem/texto", isOn: $settings.showText)
                Picker("Atualizar a cada", selection: $settings.refreshSeconds) {
                    Text("5 s").tag(5); Text("15 s").tag(15); Text("30 s").tag(30); Text("1 min").tag(60)
                }
            }
            Section("Limite da janela") {
                Picker("Plano", selection: $settings.limitPreset) {
                    ForEach(LimitPreset.allCases) { Text($0.label).tag($0) }
                }
                if settings.limitPreset == .custom {
                    TextField("Tokens", value: $settings.customLimit, format: .number)
                }
                Toggle("Contar leitura de cache", isOn: $settings.includeCacheReads)
                Toggle("Usar % oficial do Claude Code", isOn: $settings.useOfficialAPI)
                    .onChange(of: settings.useOfficialAPI) { store.officialOptionChanged() }
                if settings.useOfficialAPI {
                    Text(store.officialDenied
                         ? "Acesso ao Keychain negado. Desligue e ligue de novo para tentar outra vez."
                         : "Lê o login do Claude Code no Keychain. O macOS pede sua senha: escolha “Sempre Permitir”.")
                        .font(.caption)
                        .foregroundStyle(store.officialDenied ? .red : .secondary)
                }
            }
            Section("Alertas") {
                LabeledContent("Laranja abaixo de \(100 - Int(settings.warnPercent))% restante") {
                    Slider(value: $settings.warnPercent, in: 30...100, step: 5)
                }
                LabeledContent("Vermelho abaixo de \(100 - Int(settings.criticalPercent))% restante") {
                    Slider(value: $settings.criticalPercent, in: 30...100, step: 5)
                }
                Toggle("Notificar quando ficar vermelho", isOn: $settings.notify)
                    .onChange(of: settings.notify) { _, on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        loginStatus = SMAppService.mainApp.status
                        launchAtLogin = [.enabled, .requiresApproval].contains(loginStatus)
                    }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Falta aprovar em Itens de Início.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Abrir Ajustes") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Abrir junto com o Claude Code", isOn: $openWithClaude)
                    .help("Adiciona um hook SessionStart em ~/.claude/settings.json")
                    .onChange(of: openWithClaude) { _, on in
                        do {
                            try on ? ClaudeHook.install() : ClaudeHook.uninstall()
                            hookError = nil
                        } catch {
                            hookError = error.localizedDescription
                            openWithClaude = ClaudeHook.isInstalled
                        }
                    }
                if let hookError { Text(hookError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .padding(.horizontal, -14)
    }
}

// MARK: - Escolha do ícone

/// Grade com uma prévia de cada estilo; clique para escolher.
private struct IconStylePicker: View {
    @Binding var selection: IconStyle
    let descending: Bool
    let tint: NSColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ícone")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(IconStyle.allCases) { style in
                    Button { selection = style } label: {
                        VStack(spacing: 5) {
                            preview(style).frame(height: 18)
                            Text(style.label).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(selection == style ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selection == style ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func preview(_ style: IconStyle) -> some View {
        if let img = StatusIcon.image(style: style, fill: descending ? 0.65 : 0.35, tint: tint) {
            HStack(spacing: 3) {
                Image(nsImage: img).renderingMode(tint == nil ? .template : .original)
                Text(descending ? "65%" : "35%").font(.system(size: 11)).monospacedDigit()
            }
        } else {
            Text(descending ? "65%" : "35%").font(.system(size: 12)).monospacedDigit()
        }
    }
}

/// Barra de progresso com cor própria (o ProgressView do macOS ignora .tint).
private struct LevelBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color.gradient)
                    .frame(width: max(geo.size.width * min(max(value, 0), 1), value > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}
