import CoreGraphics
import CoreImage
import Foundation
import PaperVeilCore

/// Composes a page as a single grayscale raster image (a "scan").
/// All drawing happens in *point space* (like the PDF pages); the bitmap is
/// scaled by dpi/72 so the recorded rects are directly comparable with
/// text-PDF rects.
final class RasterPage {
    let ctx: CGContext
    let scale: CGFloat
    let pageBounds: CGRect

    init(size: CGSize, dpi: CGFloat) {
        scale = dpi / 72.0
        pageBounds = CGRect(origin: .zero, size: size)
        let pxW = Int((size.width * scale).rounded())
        let pxH = Int((size.height * scale).rounded())
        ctx = CGContext(data: nil, width: pxW, height: pxH,
                        bitsPerComponent: 8, bytesPerRow: pxW,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // White paper background.
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: pxW, height: pxH)))
        // Draw in point space from here on.
        ctx.scaleBy(x: scale, y: scale)
    }

    var image: CGImage {
        ctx.makeImage()!
    }

    // MARK: drawing (point space, mirrors PDFDoc)

    @discardableResult
    func draw(_ text: String, font: FontSpec, at baseline: CGPoint,
              color: CGColor = kFontBlack) -> PlacedLine {
        PlacedLine(pageIndex: 0, drawn: TextRender.draw(ctx, text, font: font, at: baseline, color: color))
    }

    @discardableResult
    func drawParagraph(_ text: String, font: FontSpec, at origin: CGPoint, maxWidth: CGFloat,
                       leading: CGFloat, color: CGColor = kFontBlack) -> [PlacedLine] {
        TextRender.drawParagraph(ctx, text, font: font, at: origin, maxWidth: maxWidth,
                                 leading: leading, color: color)
            .map { PlacedLine(pageIndex: 0, drawn: $0) }
    }

    func rule(from a: CGPoint, to b: CGPoint, width: CGFloat = 0.8, color: CGColor = kFontGray) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    func fill(_ rect: CGRect, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    @discardableResult
    func drawFooter(size: CGSize) -> PlacedLine {
        let text = Fiction.footer
        let w = TextRender.width(of: text, font: .helveticaOblique(7))
        return draw(text, font: .helveticaOblique(7),
                    at: CGPoint(x: size.width / 2 - w / 2, y: 16), color: kFontGray)
    }

    /// Draws a QR code (deterministic, fictional content) and returns its rect.
    func drawQR(content: String, at topLeft: CGPoint, size: CGFloat) -> CGRect {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qrImage = filter.outputImage!
        // Render at high resolution to get crisp modules.
        let scaled = qrImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = CIContext().createCGImage(scaled, from: scaled.extent)!
        // Scale to fit the requested square rect (aspect is 1:1).
        let rect = CGRect(x: topLeft.x, y: topLeft.y - size, width: size, height: size)
        ctx.draw(cg, in: rect)
        return rect
    }
}

// MARK: - Scan degradation (deterministic)

enum ScanEffects {
    /// Add white noise to a grayscale bitmap.
    static func addNoise(_ image: CGImage, amount: Int, seed: UInt64) -> CGImage {
        guard let data = pixelData(image) else { return image }
        var bytes = data.bytes
        var rng = SeededRNG(seed: seed)
        for i in bytes.indices {
            let n = Int(rng.next() % UInt64(2 * amount + 1)) - amount
            let v = Int(bytes[i]) + n
            bytes[i] = UInt8(max(0, min(255, v)))
        }
        return imageFromPixels(bytes, width: image.width, height: image.height)
    }

    /// Simple separable box blur (radius in pixels), two passes.
    static func boxBlur(_ image: CGImage, radius: Int) -> CGImage {
        guard radius > 0, let d = pixelData(image) else { return image }
        let w = image.width, h = image.height
        var a = d.bytes
        var b = [UInt8](repeating: 0, count: a.count)
        let window = 2 * radius + 1
        // horizontal
        for y in 0..<h {
            var sum = 0
            for k in -radius...radius { sum += Int(a[y * w + max(0, min(w - 1, k))]) }
            for x in 0..<w {
                b[y * w + x] = UInt8(sum / window)
                let out = Int(a[y * w + max(0, x - radius)])
                let inc = Int(a[y * w + min(w - 1, x + radius + 1)])
                sum += inc - out
            }
        }
        // vertical
        for x in 0..<w {
            var sum = 0
            for k in -radius...radius { sum += Int(b[max(0, min(h - 1, k)) * w + x]) }
            for y in 0..<h {
                a[y * w + x] = UInt8(sum / window)
                let out = Int(b[max(0, y - radius) * w + x])
                let inc = Int(b[min(h - 1, y + radius + 1) * w + x])
                sum += inc - out
            }
        }
        return imageFromPixels(a, width: w, height: h)
    }

    /// Downscale by an integer-ish factor (softens details like a bad scan).
    static func downscale(_ image: CGImage, by factor: CGFloat) -> CGImage {
        let w = Int((CGFloat(image.width) / factor).rounded())
        let h = Int((CGFloat(image.height) / factor).rounded())
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Slight rotation on a white canvas (skewed scan). Rotated content keeps
    /// its position (no overscan); corners may clip a few pixels, like a real
    /// crooked scan.
    static func skew(_ image: CGImage, degrees: Double, canvas: CGSize) -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()!
    }

    // MARK: pixel helpers

    struct Pixels { let bytes: [UInt8] }

    private static func pixelData(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(bytes: bytes)
    }

    private static func imageFromPixels(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        var copy = bytes
        let ctx = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }
}
