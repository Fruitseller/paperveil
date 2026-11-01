import AppKit
import CoreGraphics

// HIG-konforme Ebenen: quadratisch, 1024 pt, unmaskiert, ohne eingebrannte Effekte.
let S: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

// Geometrie (y nach oben). Dokument zentriert, großzügiger Rand.
let doc = CGRect(x: 292, y: 196, width: 440, height: 600)
let fold: CGFloat = 120
let lineX = doc.minX + 64, lineW = doc.width - 128, lineH: CGFloat = 34
let rows: [CGFloat] = [626, 546, 466, 386, 306]       // y der Zeilen von oben nach unten
let redacted: Set<Int> = [1, 3]                        // geschwärzte Zeilen
let shortRows: [Int: CGFloat] = [4: 0.62, 0: 0.78]     // kürzere Zeilen

func docPath() -> CGPath {
    let p = CGMutablePath(); let r: CGFloat = 36
    p.move(to: CGPoint(x: doc.minX + r, y: doc.minY))
    p.addLine(to: CGPoint(x: doc.maxX - r, y: doc.minY))
    p.addArc(tangent1End: CGPoint(x: doc.maxX, y: doc.minY), tangent2End: CGPoint(x: doc.maxX, y: doc.minY + r), radius: r)
    p.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
    p.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
    p.addLine(to: CGPoint(x: doc.minX + r, y: doc.maxY))
    p.addArc(tangent1End: CGPoint(x: doc.minX, y: doc.maxY), tangent2End: CGPoint(x: doc.minX, y: doc.maxY - r), radius: r)
    p.addLine(to: CGPoint(x: doc.minX, y: doc.minY + r))
    p.addArc(tangent1End: CGPoint(x: doc.minX, y: doc.minY), tangent2End: CGPoint(x: doc.minX + r, y: doc.minY), radius: r)
    p.closeSubpath(); return p
}
func foldPath() -> CGPath {
    let p = CGMutablePath(); let r: CGFloat = 18
    p.move(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
    p.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY - fold + r))
    p.addArc(tangent1End: CGPoint(x: doc.maxX - fold, y: doc.maxY - fold), tangent2End: CGPoint(x: doc.maxX - fold + r, y: doc.maxY - fold), radius: r)
    p.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
    p.closeSubpath(); return p
}
func pill(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height/2, cornerHeight: r.height/2, transform: nil) }

enum Layer: String, CaseIterable { case background, document, lines, redaction }

func draw(_ ctx: CGContext, _ layers: [Layer]) {
    for l in layers {
        ctx.saveGState()
        if l != .background { // Vordergrund um die Mitte vergrößern
            ctx.translateBy(x: S/2, y: S/2); ctx.scaleBy(x: 1.2, y: 1.2); ctx.translateBy(x: -S/2, y: -S/2)
        }
        defer { ctx.restoreGState() }
        switch l {
        case .background:
            // dezenter vertikaler Verlauf, randlos und deckend
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(46, 64, 92), rgb(24, 33, 51)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
        case .document:
            ctx.addPath(docPath()); ctx.setFillColor(rgb(248, 249, 251)); ctx.fillPath()
            ctx.addPath(foldPath()); ctx.setFillColor(rgb(214, 220, 229)); ctx.fillPath()
        case .lines:
            for (i, y) in rows.enumerated() where !redacted.contains(i) {
                ctx.addPath(pill(CGRect(x: lineX, y: y, width: lineW * (shortRows[i] ?? 1), height: lineH)))
                ctx.setFillColor(rgb(176, 186, 201)); ctx.fillPath()
            }
            // Text unter den Balken, schimmert durch die halbtransparenten Balken
            for i in redacted { ctx.addPath(pill(CGRect(x: lineX, y: rows[i], width: lineW, height: lineH))); ctx.setFillColor(rgb(176, 186, 201)); ctx.fillPath() }
        case .redaction:
            for i in redacted {
                ctx.addPath(pill(CGRect(x: lineX - 22, y: rows[i] - 16, width: lineW + 44, height: lineH + 32)))
                ctx.setFillColor(rgb(17, 20, 28, 0.74)); ctx.fillPath()
            }
        }
    }
}

func pdf(_ name: String, _ layers: [Layer]) {
    var box = CGRect(x: 0, y: 0, width: S, height: S)
    let ctx = CGContext(out.appendingPathComponent(name) as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil); draw(ctx, layers); ctx.endPDFPage(); ctx.closePDF()
}
func png(_ name: String, _ layers: [Layer], masked: Bool = false) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if masked { // nur für die Vorschau: ungefähre macOS-Maske
        ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)); ctx.clip()
        ctx.translateBy(x: 100, y: 100); ctx.scaleBy(x: 824/S, y: 824/S)
    }
    draw(ctx, layers)
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

// Ebenen für Icon Composer (Vektor-PDF + PNG)
pdf("1-background.pdf", [.background]); png("1-background.png", [.background])
pdf("2-document.pdf", [.document]);     png("2-document.png", [.document])
pdf("3-lines.pdf", [.lines]);           png("3-lines.png", [.lines])
pdf("4-redaction.pdf", [.redaction]);   png("4-redaction.png", [.redaction])
// Vorschau ohne Systemeffekte
png("preview-flat-1024.png", Layer.allCases)
png("preview-masked.png", Layer.allCases, masked: true)
