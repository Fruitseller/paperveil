import CoreGraphics
import Foundation

/// Geometry of one PDF page: how its unrotated page space relates to the space
/// "as displayed" (after applying /Rotate and the crop box). All public word
/// rectangles are in *unrotated page space* — the coordinate system of
/// `PDFPage.bounds(for: .mediaBox)`, origin at the lower-left of the page,
/// independent of /Rotate — so detections stay stable when a viewer rotates a page.
struct PageGeometry: Sendable {
    /// Crop box in PDFKit page space (may be offset inside the media box).
    let crop: CGRect
    /// /Rotate value normalized to 0, 90, 180 or 270 (clockwise when displayed).
    let rotation: Int

    init(crop: CGRect, rotation: Int) {
        self.crop = crop
        let r = ((rotation % 360) + 360) % 360
        self.rotation = (r == 90 || r == 180 || r == 270) ? r : 0
    }

    /// Size of the page as displayed (crop box with /Rotate applied), in points.
    var displayedSize: CGSize {
        let w = crop.width, h = crop.height
        return rotation == 90 || rotation == 270 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Maps a point from unrotated page space into displayed space
    /// (origin at the lower-left of the *displayed* crop area, in points).
    ///
    /// /Rotate is clockwise when displayed: with rotation 90, the left edge of
    /// the unrotated page becomes the top edge of the displayed page.
    func displayedPoint(for pagePoint: CGPoint) -> CGPoint {
        let q = CGPoint(x: pagePoint.x - crop.minX, y: pagePoint.y - crop.minY)
        let w = crop.width, h = crop.height
        switch rotation {
        case 90: return CGPoint(x: q.y, y: w - q.x)
        case 180: return CGPoint(x: w - q.x, y: h - q.y)
        case 270: return CGPoint(x: h - q.y, y: q.x)
        default: return q
        }
    }

    /// Maps an axis-aligned rect from unrotated page space to displayed space.
    /// Stays axis-aligned because only multiples of 90° are involved.
    func displayedRect(for pageRect: CGRect) -> CGRect {
        let points = [pageRect.origin,
                      CGPoint(x: pageRect.maxX, y: pageRect.minY),
                      CGPoint(x: pageRect.minX, y: pageRect.maxY),
                      CGPoint(x: pageRect.maxX, y: pageRect.maxY)]
            .map { displayedPoint(for: $0) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Sort key for reading order in *displayed* space: top lines before lower
    /// lines, left before right. Comparing tuples gives the ordering directly.
    func readingOrderKey(for pageRect: CGRect) -> (Double, Double) {
        let d = displayedRect(for: pageRect)
        return (-d.midY, d.minX)
    }

    /// Maps a normalized Vision rectangle (bottom-left origin, relative to the
    /// rendered bitmap of the *displayed* page) back to unrotated page space.
    /// `imagePixelSize` is the pixel size of that bitmap, `scale` its pixels per point.
    func pageRect(fromNormalizedRect normalized: CGRect, imagePixelSize: CGSize, scale: CGFloat) -> CGRect {
        let dispW = imagePixelSize.width / scale
        let dispH = imagePixelSize.height / scale
        func toPage(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            let dx = nx * dispW, dy = ny * dispH
            let w = crop.width, h = crop.height
            let qx: CGFloat, qy: CGFloat
            switch rotation {
            case 90: qx = w - dy; qy = dx
            case 180: qx = w - dx; qy = h - dy
            case 270: qx = dy; qy = h - dx
            default: qx = dx; qy = dy
            }
            return CGPoint(x: crop.minX + qx, y: crop.minY + qy)
        }
        let corners = [toPage(normalized.minX, normalized.minY),
                       toPage(normalized.maxX, normalized.maxY),
                       toPage(normalized.minX, normalized.maxY),
                       toPage(normalized.maxX, normalized.minY)]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
