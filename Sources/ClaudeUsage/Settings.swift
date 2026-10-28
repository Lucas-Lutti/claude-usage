import AppKit
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case used, remaining, tokens, timeLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .used: "% usado"
        case .remaining: "% restante (100 → 0)"
        case .tokens: "Tokens usados"
        case .timeLeft: "Tempo até o reset"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case ring, bar, segments, rays, battery, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ring: "Anel"
        case .bar: "Barra"
        case .segments: "Blocos"
        case .rays: "Raios"
        case .battery: "Bateria"
        case .none: "Sem ícone"
        }
    }
}

enum LimitPreset: String, CaseIterable, Identifiable {
    case pro, max5, max20, auto, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pro: "Pro (~1M)"
        case .max5: "Max 5x (~5M)"
        case .max20: "Max 20x (~20M)"
        case .auto: "Automático (maior janela já usada)"
        case .custom: "Personalizado"
        }
    }
    /// Estimativas: a Anthropic não publica limites em tokens.
    var tokens: Int? {
        switch self {
        case .pro: 1_000_000
        case .max5: 5_000_000
        case .max20: 20_000_000
        case .auto, .custom: nil
        }
    }
}

final class Settings: ObservableObject {
    @AppStorage("displayMode") var displayMode: DisplayMode = .remaining
    @AppStorage("iconStyle") var iconStyle: IconStyle = .segments
    @AppStorage("colorful") var colorful = true
    @AppStorage("limitPreset") var limitPreset: LimitPreset = .max5
    @AppStorage("customLimit") var customLimit: Int = 3_000_000
    @AppStorage("includeCacheReads") var includeCacheReads = false
    @AppStorage("showText") var showText = true
    @AppStorage("refreshSeconds") var refreshSeconds: Int = 15
    // Em % usado: laranja a partir da metade, vermelho nos últimos 15%.
    @AppStorage("warnPercent") var warnPercent: Double = 50
    @AppStorage("criticalPercent") var criticalPercent: Double = 85
    // Ligado por padrão (é a % exata). Ler o login do Claude Code no Keychain faz o macOS pedir a senha;
    // se a pessoa negar, o UsageStore desliga a opção.
    @AppStorage("officialAPIOptIn") var useOfficialAPI = true
    @AppStorage("notify") var notify = true
    @AppStorage("hookSetupDone") var hookSetupDone = false
    /// Tela de boas-vindas vista: só depois dela o app pede permissões (notificação e Keychain).
    @AppStorage("onboarded") var onboarded = false

    func level(usedPercent p: Double) -> UsageLevel {
        p >= criticalPercent ? .critical : p >= warnPercent ? .warn : .ok
    }
}

enum UsageLevel {
    case ok, warn, critical

    var color: Color {
        switch self { case .ok: .green; case .warn: .orange; case .critical: .red }
    }
    var nsColor: NSColor {
        switch self { case .ok: .systemGreen; case .warn: .systemOrange; case .critical: .systemRed }
    }
}
