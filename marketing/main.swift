// Gera as imagens de divulgação (README, GitHub e LinkedIn) a partir das telas reais do app,
// com dados de demonstração. Rode: ./marketing/render.sh
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images")
let now = Date()

// MARK: - Dados de demonstração

@MainActor func demoSnapshot() -> UsageSnapshot {
    let projects = ["api-pagamentos", "site-portfolio", "app-mobile"]
    var entries: [UsageEntry] = []

    func burst(from start: Date, count: Int, every minutes: Double, target: Double, phase: Double) {
        var raw: [(Date, Double, String)] = []
        for i in 0..<count {
            let w = 0.35 + abs(sin(Double(i) * 0.41 + phase)) * 1.2 + (i % 7 == 0 ? 0.8 : 0)
            raw.append((start.addingTimeInterval(Double(i) * minutes * 60), w, projects[(i / 9 + Int(phase)) % projects.count]))
        }
        let k = target / raw.reduce(0) { $0 + $1.1 }
        for (ts, w, project) in raw {
            let n = w * k
            entries.append(UsageEntry(timestamp: ts, model: "claude-opus-5-5", project: project,
                                      tokens: Tokens(input: Int(n * 0.002), output: Int(n * 0.16),
                                                     cacheWrite: Int(n * 0.838), cacheRead: Int(n * 5.5))))
        }
    }

    // Dias anteriores, um bloco mais cedo hoje e a janela atual (~38% usado → 62% restante).
    for d in [5.0, 3.0, 2.0, 1.0] { burst(from: now.addingTimeInterval(-d * 86400 - 3600), count: 40, every: 3, target: 2_600_000, phase: d) }
    burst(from: now.addingTimeInterval(-9 * 3600), count: 35, every: 3, target: 1_400_000, phase: 2)
    burst(from: now.addingTimeInterval(-142 * 60), count: 70, every: 2, target: 1_900_000, phase: 0)

    entries.sort { $0.timestamp < $1.timestamp }
    return UsageSnapshot(blocks: Block.build(from: entries), entries: entries, scannedAt: now, filesTracked: 12)
}

// MARK: - Captura das telas reais

/// Desenha uma view com controles AppKit (Picker, Form) numa janela fora da tela.
@MainActor func capture<V: View>(_ view: V, dark: Bool) -> NSImage {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    return img
}

@MainActor func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, pixelWidth: CGFloat, _ name: String) {
    let r = ImageRenderer(content: view.frame(width: width, height: height))
    r.scale = pixelWidth / width
    guard let cg = r.cgImage else { print("falhou: \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("ok  \(name)  \(cg.width)×\(cg.height)")
}

// MARK: - Peças visuais

/// Mesmo desenho do ícone "Blocos" (StatusIcon), em vetor para ampliar sem borrar.
@MainActor struct Blocks: View {
    let fill: Double
    let level: UsageLevel
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 1.5 * scale) {
            ForEach(0..<5) { i in
                let part = min(max(fill * 5 - Double(i), 0), 1)
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(level.color.opacity(0.28))
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Rectangle().fill(level.color).frame(width: g.size.width * part)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1.5 * scale))
            }
        }
        .frame(width: 27 * scale, height: 10 * scale)
    }
}

@MainActor struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.17),
                                    Color(red: 0.36, green: 0.17, blue: 0.27),
                                    Color(red: 0.86, green: 0.47, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.7, blue: 0.45).opacity(0.35))
                .frame(width: 600).blur(radius: 140).offset(x: 260, y: 220)
            Circle().fill(Color(red: 0.35, green: 0.3, blue: 0.9).opacity(0.35))
                .frame(width: 500).blur(radius: 150).offset(x: -300, y: -200)
        }
    }
}

/// Barra de menus falsa com o item do app em destaque.
@MainActor struct MenuBarMock: View {
    let fill: Double
    let level: UsageLevel
    var clock: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE d 'de' MMM  HH:mm"
        return f.string(from: now)
    }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            Text("Arquivo"); Text("Editar"); Text("Visualizar")
            Spacer()
            HStack(spacing: 5) {
                Blocks(fill: fill, level: level)
                Text("\(Int((fill * 100).rounded()))%").monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
            Image(systemName: "wifi")
            Image(systemName: "switch.2")
            Text(clock)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.black.opacity(0.28))
    }
}

@MainActor struct Card: View {
    let image: NSImage
    var width: CGFloat = 340
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high)
            .frame(width: width, height: width * image.size.height / image.size.width)
            .clipShape(RoundedRectangle(cornerRadius: 14 * width / 340, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14 * width / 340, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }
}

/// Área de trabalho: barra de menus + painel aberto logo abaixo do ícone.
@MainActor struct DesktopScene: View {
    let popover: NSImage
    var popoverWidth: CGFloat = 340
    var trailing: CGFloat = 100
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 8) {
                MenuBarMock(fill: 0.62, level: .ok)
                HStack { Spacer(); Card(image: popover, width: popoverWidth).padding(.trailing, trailing) }
                Spacer(minLength: 0)
            }
        }
    }
}

@MainActor struct StateIcon: View {
    let fill: Double
    let level: UsageLevel
    let caption: String
    var scale: CGFloat = 3
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Blocks(fill: fill, level: level, scale: scale)
                Text("\(Int(fill * 100))%").font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(caption).font(.system(size: 4.5 * scale, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct StatesRow: View {
    var scale: CGFloat = 3
    var body: some View {
        HStack(spacing: 14 * scale) {
            StateIcon(fill: 1.0, level: .ok, caption: "janela nova", scale: scale)
            StateIcon(fill: 0.62, level: .ok, caption: "tranquilo", scale: scale)
            StateIcon(fill: 0.35, level: .warn, caption: "metade pra baixo", scale: scale)
            StateIcon(fill: 0.10, level: .critical, caption: "reta final", scale: scale)
        }
    }
}

@MainActor struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
    }
}

// MARK: - Geração

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let settings = Settings()
    let store = UsageStore(settings: settings)
    store.load(demoSnapshot())

    // Tela de boas-vindas (primeira abertura) e, depois, as telas normais.
    settings.onboarded = false
    let boasVindas = capture(PopoverView().environmentObject(store).environmentObject(settings), dark: true)
    settings.onboarded = true

    @MainActor func popover(tab: Int, dark: Bool) -> NSImage {
        capture(PopoverView(initialTab: tab).environmentObject(store).environmentObject(settings), dark: dark)
    }
    let usoClaro = popover(tab: 0, dark: false)
    let usoEscuro = popover(tab: 0, dark: true)
    let personalizar = popover(tab: 1, dark: true)

    // Telas soltas para o README (fundo transparente).
    for (img, name) in [(usoClaro, "painel-uso-claro.png"), (usoEscuro, "painel-uso-escuro.png"),
                        (personalizar, "painel-personalizar.png"), (boasVindas, "painel-boas-vindas.png")] {
        save(Card(image: img).padding(40), width: 420, height: img.size.height * 340 / img.size.width + 80,
             pixelWidth: 840, name)
    }

    // Hero do README.
    save(DesktopScene(popover: usoEscuro), width: 1200, height: 720, pixelWidth: 2400, "hero.png")

    // Estados do ícone.
    save(StatesRow().padding(.horizontal, 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.97)).environment(\.colorScheme, .light),
         width: 900, height: 200, pixelWidth: 1800, "estados.png")

    // Prévia social do GitHub (1280×640).
    save(ZStack {
        Wallpaper()
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Claude Usage").font(.system(size: 64, weight: .bold, design: .rounded))
                Text("Sua janela de 5h do Claude,\nao vivo na barra de menus do Mac.")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 10) { Chip(text: "macOS"); Chip(text: "Swift"); Chip(text: "Open source") }
                    .padding(.top, 8)
            }
            Spacer()
            Card(image: usoEscuro, width: 330).rotationEffect(.degrees(2))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 70)
    }, width: 1280, height: 640, pixelWidth: 1280, "github-social-preview.png")

    // LinkedIn retrato (1080×1350).
    save(ZStack(alignment: .top) {
        Wallpaper()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("PROJETO PESSOAL · macOS").font(.system(size: 16, weight: .bold)).kerning(2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Quanto ainda resta da\nminha janela de 5h\ndo Claude?")
                    .font(.system(size: 48, weight: .bold, design: .rounded)).lineSpacing(2)
                Text("Criei um app de barra de menus que mostra o consumo ao vivo — de 100% até 0%.")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 56).padding(.top, 48)

            Spacer(minLength: 30)
            VStack(spacing: 8) {
                MenuBarMock(fill: 0.62, level: .ok)
                HStack { Spacer(); Card(image: usoEscuro, width: 290).padding(.trailing, 125) }
            }
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
    }, width: 720, height: 900, pixelWidth: 1080, "linkedin-retrato.png")

    // LinkedIn retrato sem texto: só a barra de menus e o painel, maiores.
    save(ZStack {
        Wallpaper()
        VStack(spacing: 10) {
            MenuBarMock(fill: 0.62, level: .ok)
            HStack { Spacer(); Card(image: usoEscuro, width: 440).padding(.trailing, 51) }
        }
    }, width: 720, height: 900, pixelWidth: 1080, "linkedin-retrato-sem-texto.png")

    // LinkedIn paisagem (1200×627).
    save(ZStack {
        Wallpaper()
        HStack(alignment: .center, spacing: 30) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Claude Usage").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                Text("Minha janela de 5h do Claude, ao vivo na barra de menus.")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                HStack(spacing: 14) {
                    ForEach([(1.0, UsageLevel.ok), (0.35, .warn), (0.1, .critical)], id: \.0) { f, l in
                        Blocks(fill: f, level: l, scale: 2)
                    }
                }
                .padding(.top, 6)
            }
            Card(image: usoEscuro, width: 300)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 60)
    }, width: 1200, height: 627, pixelWidth: 1200, "linkedin-paisagem.png")
}
