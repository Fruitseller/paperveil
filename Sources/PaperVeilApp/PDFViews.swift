import AppKit
import PDFKit
import PaperVeilCore
import SwiftUI

/// Read-only PDF view of the ORIGINAL with finding overlays. The document is
/// loaded into memory and never written back; overlays are display-only annotations.
/// In marking mode, dragging a rectangle reports it in page space (unrotated mediaBox).
struct OriginalPDFView: NSViewRepresentable {
    let url: URL
    let findings: [Finding]
    let highlighted: UUID?
    let markingEnabled: Bool
    let onMark: (Int, PageRect) -> Void

    func makeNSView(context: Context) -> MarkingPDFView {
        let v = MarkingPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.unregisterDraggedTypes() // file drops go to the app's import handler, not into the viewer
        return v
    }

    func updateNSView(_ v: MarkingPDFView, context: Context) {
        if v.loadedURL != url {
            v.loadedURL = url
            // Load from Data so the file on disk is never held open for writing.
            v.document = (try? Data(contentsOf: url)).flatMap { PDFDocument(data: $0) }
        }
        v.markingEnabled = markingEnabled
        v.onMark = onMark
        v.applyOverlays(findings: findings, highlighted: highlighted)
    }
}

final class MarkingPDFView: PDFView {
    var loadedURL: URL?
    var markingEnabled = false
    var onMark: ((Int, PageRect) -> Void)?
    private var overlayKeys: [ObjectIdentifier: [PDFAnnotation]] = [:]
    private var dragStart: (PDFPage, CGPoint)?
    private var rubberBand: PDFAnnotation?

    func applyOverlays(findings: [Finding], highlighted: UUID?) {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in overlayKeys[ObjectIdentifier(page)] ?? [] { page.removeAnnotation(a) }
            overlayKeys[ObjectIdentifier(page)] = []
        }
        for f in findings {
            guard let page = doc.page(at: f.pageIndex) else { continue }
            for r in f.rects {
                let a = PDFAnnotation(bounds: r.cgRect, forType: .square, withProperties: nil)
                let color: NSColor = switch f.decision {
                case .rejected: .systemGray
                case .accepted: .systemRed
                case .proposed: .systemOrange
                }
                a.color = color
                a.interiorColor = color.withAlphaComponent(f.decision == .rejected ? 0.08 : (f.id == highlighted ? 0.55 : 0.3))
                let b = PDFBorder(); b.lineWidth = f.id == highlighted ? 2.5 : 1
                a.border = b
                a.isReadOnly = true
                page.addAnnotation(a)
                overlayKeys[ObjectIdentifier(page), default: []].append(a)
            }
        }
        if let h = highlighted, let f = findings.first(where: { $0.id == h }), let page = doc.page(at: f.pageIndex),
           let r = f.rects.first {
            go(to: r.cgRect.insetBy(dx: -40, dy: -40), on: page)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard markingEnabled else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return }
        dragStart = (page, convert(p, to: page))
    }

    override func mouseDragged(with event: NSEvent) {
        guard markingEnabled, let (page, start) = dragStart else { return super.mouseDragged(with: event) }
        let cur = convert(convert(event.locationInWindow, from: nil), to: page)
        if let rb = rubberBand { page.removeAnnotation(rb) }
        let rb = PDFAnnotation(bounds: rect(start, cur), forType: .square, withProperties: nil)
        rb.color = .systemBlue
        page.addAnnotation(rb)
        rubberBand = rb
    }

    override func mouseUp(with event: NSEvent) {
        guard markingEnabled, let (page, start) = dragStart else { return super.mouseUp(with: event) }
        if let rb = rubberBand { page.removeAnnotation(rb) }
        rubberBand = nil; dragStart = nil
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        let r = rect(start, end)
        guard r.width > 3, r.height > 3, let doc = document else { return }
        onMark?(doc.index(for: page), PageRect(r))
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Plain read-only view of the exported (cleaned) PDF.
struct ExportPDFView: NSViewRepresentable {
    let url: URL?
    final class View: PDFView { var loadedURL: URL? }
    func makeNSView(context: Context) -> View {
        let v = View(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.unregisterDraggedTypes(); return v
    }
    func updateNSView(_ v: View, context: Context) {
        guard v.loadedURL != url else { return }
        v.loadedURL = url
        v.document = url.flatMap { u in (try? Data(contentsOf: u)).flatMap { PDFDocument(data: $0) } }
    }
}
