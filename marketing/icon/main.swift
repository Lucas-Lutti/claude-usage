// Gera o ícone do app (AppIcon.icns) e prévias das variantes. Rode: ./marketing/icon.sh
//   icon <variante> <saída.png>       uma prévia 1024×1024
//   icon <variante> --iconset <pasta> todos os tamanhos de um .iconset
import AppKit
import SwiftUI

enum Variant: String, CaseIterable { case escuro, cores, quente }

let green = Color(red: 0.20, green: 0.80, blue: 0.40)
let orange = Color(red: 1.00, green: 0.58, blue: 0.18)
let red = Color(red: 1.00, green: 0.27, blue: 0.27)

/// Cinco blocos, como o ícone da barra de menus. `fills` vai de 0 a 1 por bloco.
struct Blocks: View {
    let colors: [Color]
    let fills: [Double]
    let track: Color

    var body: some View {
        HStack(spacing: 26) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(track)
                    .overlay(alignment: .bottom) {
                        GeometryReader { g in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(colors[i].gradient)
                                    .frame(height: g.size.height * fills[i])
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .frame(width: 80, height: 300)
            }
        }
    }
}

struct AppIcon: View {
    let variant: Variant

    var background: some View {
        switch variant {
        case .escuro:
            LinearGradient(colors: [Color(red: 0.17, green: 0.16, blue: 0.24), Color(red: 0.07, green: 0.07, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
        case .cores:
            LinearGradient(colors: [Color(white: 1), Color(red: 0.93, green: 0.93, blue: 0.95)],
                           startPoint: .top, endPoint: .bottom)
        case .quente:
            LinearGradient(colors: [Color(red: 0.36, green: 0.20, blue: 0.48), Color(red: 0.90, green: 0.48, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var blocks: some View {
        switch variant {
        case .escuro:
            Blocks(colors: Array(repeating: green, count: 5), fills: [1, 1, 1, 0.45, 0],
                   track: .white.opacity(0.12))
        case .cores:
            Blocks(colors: [red, orange, orange, green, green], fills: [1, 1, 1, 1, 1],
                   track: .black.opacity(0.06))
        case .quente:
            Blocks(colors: Array(repeating: .white, count: 5), fills: [1, 1, 1, 0.45, 0],
                   track: .white.opacity(0.22))
        }
    }

    var body: some View {
        ZStack {
            // Área do ícone no grid do macOS: 824×824 dentro de 1024×1024.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(AnyShapeStyle(.clear))
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(.white.opacity(variant == .cores ? 0 : 0.10), lineWidth: 2))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(.black.opacity(variant == .cores ? 0.08 : 0), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 10)
            blocks
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ variant: Variant, size: Int) -> Data {
    let r = ImageRenderer(content: AppIcon(variant: variant))
    r.scale = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    return rep.representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    guard args.count >= 3, let variant = Variant(rawValue: args[1]) else {
        print("uso: icon <\(Variant.allCases.map(\.rawValue).joined(separator: "|"))> <saída.png | --iconset pasta>")
        exit(1)
    }
    if args[2] == "--iconset", args.count >= 4 {
        let dir = URL(fileURLWithPath: args[3])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try! render(variant, size: base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
            try! render(variant, size: base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
    } else {
        try! render(variant, size: 1024).write(to: URL(fileURLWithPath: args[2]))
    }
}
