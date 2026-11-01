import CoreGraphics
import Foundation

/// Geometry of one PDF page *as displayed*: cropBox honoured, `/Rotate` applied.
/// All inputs are expressed in PDF user space, i.e. the unrotated mediaBox
/// coordinate system in which `Finding.rects` (`PageRect`) are defined.
struct PageGeometry {
    /// Crop box in user space (origin may be non-zero if the cropBox is offset
    /// relative to the mediaBox).
    let cropBox: CGRect
    /// Rotation in degrees, normalized to 0/90/180/270 (clockwise when displayed).
    let rotation: Int
    /// Size of the page as displayed, in points.
    let displayedSize: CGSize

    /// Returns the display geometry for a page, or nil if the page has no usable
    /// crop box or a rotation that is not a multiple of 90°.
    static func displayed(_ page: CGPDFPage) -> PageGeometry? {
        let crop = page.getBoxRect(.cropBox)
        guard crop.width > 0, crop.height > 0, crop.width.isFinite, crop.height.isFinite else { return nil }
        let raw = ((Int(page.rotationAngle) % 360) + 360) % 360
        guard raw % 90 == 0 else { return nil }
        let rotated = raw == 90 || raw == 270
        return PageGeometry(
            cropBox: crop,
            rotation: raw,
            displayedSize: CGSize(
                width: rotated ? crop.height : crop.width,
                height: rotated ? crop.width : crop.height
            )
        )
    }

    /// Transform from user space (unrotated mediaBox coordinates) to display
    /// points: origin at the lower-left corner of the *displayed* page, y up.
    /// For `/Rotate 90` the page is rotated 90° clockwise when displayed
    /// (PDF 32000-1, table "Page attributes").
    var userToDisplay: CGAffineTransform {
        let c = cropBox
        switch rotation {
        case 90:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -c.minY, ty: c.width + c.minX)
        case 180:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: c.width + c.minX, ty: c.height + c.minY)
        case 270:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: c.height + c.minY, ty: -c.minX)
        default:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -c.minX, ty: -c.minY)
        }
    }
}

/// One PDF page rendered into an opaque white sRGB bitmap.
///
/// The bitmap is 32 bit (B, G, R, X in memory; byte order 32 little, alpha
/// skipped), one row per displayed line, row 0 at the top of the page *as
/// displayed*. Rendering draws page content only (annotation appearances are
/// never baked in, both for safety and for consistency between exporter and
/// validator).
final class PageBitmap {
    let geometry: PageGeometry
    let dpi: Double
    let width: Int
    let height: Int
    /// User-space points (unrotated mediaBox coordinates) -> bitmap pixels in
    /// CG device space: origin at the lower-left corner of the bitmap, y up.
    /// This is the exact transform used to render the page.
    let userToPixel: CGAffineTransform
    /// Pixel data; four bytes per pixel (B, G, R, X), rows from the top.
    private(set) var buffer: [UInt8]

    init?(page: CGPDFPage, dpi: Double) {
        guard let geo = PageGeometry.displayed(page), dpi > 0 else { return nil }
        let scale = dpi / 72.0
        let w = max(1, Int((geo.displayedSize.width * scale).rounded()))
        let h = max(1, Int((geo.displayedSize.height * scale).rounded()))
        let sx = Double(w) / geo.displayedSize.width
        let sy = Double(h) / geo.displayedSize.height
        let toPixel = geo.userToDisplay.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var buf = [UInt8](repeating: 0, count: w * h * 4)
        var ok = false
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = PageBitmap.makeContext(data: raw.baseAddress, width: w, height: h, space: colorSpace)
            else { return }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.saveGState()
            ctx.concatenate(toPixel)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            ok = true
        }
        guard ok else { return nil }
        self.geometry = geo
        self.dpi = dpi
        self.width = w
        self.height = h
        self.userToPixel = toPixel
        self.buffer = buf
    }

    private static func makeContext(data: UnsafeMutableRawPointer?, width: Int, height: Int,
                                    space: CGColorSpace) -> CGContext? {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        )
    }

    /// Bitmap bounds in pixel device coordinates (origin bottom-left, y up).
    var deviceBounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Maps a user-space rect through the display transform into pixel device
    /// coordinates (origin bottom-left, y up). Rotation of 0/90/180/270 keeps
    /// rects axis-aligned. Result is not clipped to the bitmap.
    func pixelRect(forUserRect r: CGRect) -> CGRect {
        let a = CGPoint(x: r.minX, y: r.minY).applying(userToPixel)
        let b = CGPoint(x: r.maxX, y: r.maxY).applying(userToPixel)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Fills solid black into the pixels. `rects` are pixel device coordinates
    /// (origin bottom-left, y up), already clipped to the bitmap by the caller.
    func blackOut(_ rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = PageBitmap.makeContext(
                data: raw.baseAddress, width: width, height: height,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            ) else { return }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            for r in rects { ctx.fill(r) }
        }
    }

    /// The rendered page as a CGImage (lossless snapshot of the bitmap).
    var image: CGImage? {
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = PageBitmap.makeContext(
                data: raw.baseAddress, width: width, height: height,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// RGB at a pixel. `y` is the row from the top of the displayed page.
    func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let idx = (y * width + x) * 4
        return (buffer[idx + 2], buffer[idx + 1], buffer[idx])
    }

    /// Fully contained integer pixel bounds (half-open) of a pixel device rect,
    /// in "rows from the top" coordinates. Optionally shrinks the rect first.
    func pixelBounds(of rect: CGRect, inset: CGFloat = 0) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        let r = rect.insetBy(dx: inset, dy: inset)
        let x0 = max(0, min(width, Int(r.minX.rounded(.up))))
        let x1 = max(0, min(width, Int(r.maxX.rounded(.down))))
        let y0 = max(0, min(height, height - Int(r.maxY.rounded(.down))))
        let y1 = max(0, min(height, height - Int(r.minY.rounded(.up))))
        return (x0, x1, y0, y1)
    }
}
