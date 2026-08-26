import AppKit
import CoreGraphics

// Desenha o ícone do Timbre: squircle no estilo macOS com uma forma de
// onda e o ponto de gravação.

let S: CGFloat = 1024

// Em 16 e 32 px as oito barras viram borrão, então os tamanhos pequenos usam
// uma arte simplificada — o mesmo que a Apple faz nos ícones do sistema.
let outputName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let simplified = CommandLine.arguments.contains("--small")
// O macOS 26 coloca ícones .icns dentro da própria placa arredondada. Se a arte
// já trouxer moldura e margem, o resultado é um squircle dentro de outro — então
// desenhamos sangrando até a borda e deixamos o sistema aplicar a máscara.
let fullBleed = CommandLine.arguments.contains("--fullbleed")

func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let (cx, cy) = (rect.midX, rect.midY)
    let (a, b) = (rect.width / 2, rect.height / 2)
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Área do ícone: o macOS espera margem em volta da arte.
let body = fullBleed ? CGRect(x: 0, y: 0, width: S, height: S)
                     : CGRect(x: 100, y: 116, width: S - 200, height: S - 200)
let shape = fullBleed ? CGPath(rect: body, transform: nil) : squircle(in: body)

// Sombra projetada, sutil.
if !fullBleed {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: rgb(0x02070F, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0A2351))
    ctx.fillPath()
    ctx.restoreGState()
}

// Fundo em gradiente diagonal.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(0x15346E), rgb(0x0A2351), rgb(0x06152F)] as CFArray,
                    locations: [0, 0.52, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])

// Brilho suave no topo, para dar volume.
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0xFFFFFF, 0.34), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(gloss,
                       startCenter: CGPoint(x: body.midX, y: body.maxY + 40), startRadius: 10,
                       endCenter: CGPoint(x: body.midX, y: body.maxY + 40), endRadius: body.width * 0.78,
                       options: [])
ctx.restoreGState()

// Aro interno claro, o realce de borda dos ícones do sistema.
if !fullBleed {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.30))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.restoreGState()
}

// Forma de onda: cápsulas de alturas variadas, como um áudio real.
let heights: [CGFloat] = simplified
    ? [0.44, 0.78, 1.0, 0.66, 0.38]
    : [0.26, 0.50, 0.78, 1.0, 0.68, 0.88, 0.44, 0.28]
let barWidth: CGFloat = simplified ? 88 : 50
let gap: CGFloat = simplified ? 44 : 30
let accentBar = simplified ? 2 : 3   // a barra mais alta vira o ponto de gravação
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = body.midX - totalWidth / 2
let maxHeight = body.height * 0.52
let centerY = body.midY

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x02070F, 0.5))
for (index, h) in heights.enumerated() {
    let barHeight = max(maxHeight * h, barWidth)
    let bar = CGRect(x: x, y: centerY - barHeight / 2, width: barWidth, height: barHeight)
    let capsule = CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    if index == accentBar {
        ctx.saveGState()
        ctx.addPath(capsule)
        ctx.clip()
        let rec = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [rgb(0xFFD24D), rgb(0xFFC000)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(rec, start: CGPoint(x: bar.minX, y: bar.maxY),
                               end: CGPoint(x: bar.maxX, y: bar.minY), options: [])
        ctx.restoreGState()
    } else {
        ctx.addPath(capsule)
        ctx.setFillColor(rgb(0xFFFFFF, 0.97))
        ctx.fillPath()
    }
    x += barWidth + gap
}
ctx.restoreGState()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outputName)
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("\(outputName) gerado")
