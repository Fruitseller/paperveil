import CoreGraphics
import Foundation
import PDFKit

/// Scans a PDF page's content stream (via the public CGPDFScanner API) and
/// determines the largest area fraction of the page covered by a single raster
/// image. Used to detect "scan" pages (full-page images) and mixed pages
/// (text plus a large figure/scan) that should additionally be OCR'd.
struct PageImageAnalyzer {
    /// A page counts as containing a "large image" when one image covers at
    /// least this fraction of the media box area.
    static let largeImageFraction = 0.10
    /// Maximum recursion depth into Form XObjects (guards against malformed,
    /// self-referencing content streams).
    private static let maxFormDepth = 4

    /// Largest fraction of the media box covered by a single image (0 … 1).
    /// Takes nested transforms (cm/q/Q), image /Matrix entries and inline
    /// images into account.
    func largestImageFraction(page: PDFPage) -> Double {
        guard let pdfPage = page.pageRef else { return 0 }
        let mediaBox = page.bounds(for: .mediaBox)
        let area = Double(mediaBox.width * mediaBox.height)
        guard area > 0 else { return 0 }
        let contentStream = CGPDFContentStreamCreateWithPage(pdfPage)
        defer { CGPDFContentStreamRelease(contentStream) }

        let state = ScanState(pageArea: area)
        let statePointer = Unmanaged.passRetained(state).toOpaque()
        defer { Unmanaged<ScanState>.fromOpaque(statePointer).release() }
        scan(contentStream: contentStream, statePointer: statePointer)
        return state.maxFraction
    }

    /// True when the page contains an image large enough to look like a scan
    /// or a mixed text/scan page.
    func containsLargeImage(page: PDFPage) -> Bool {
        largestImageFraction(page: page) >= Self.largeImageFraction
    }

    // MARK: - Scanner plumbing

    private func scan(contentStream: CGPDFContentStreamRef, statePointer: UnsafeMutableRawPointer) {
        let state = Unmanaged<ScanState>.fromOpaque(statePointer).takeUnretainedValue()
        state.formDepth += 1
        defer { state.formDepth -= 1 }
        guard state.formDepth <= Self.maxFormDepth else { return }

        guard let table = CGPDFOperatorTableCreate() else { return }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "cm", Self.cmCallback)
        CGPDFOperatorTableSetCallback(table, "q", Self.saveCallback)
        CGPDFOperatorTableSetCallback(table, "Q", Self.restoreCallback)
        CGPDFOperatorTableSetCallback(table, "Do", Self.doCallback)
        CGPDFOperatorTableSetCallback(table, "BI", Self.inlineImageCallback)

        let scanner = CGPDFScannerCreate(contentStream, table, statePointer)
        defer { CGPDFScannerRelease(scanner) }
        _ = CGPDFScannerScan(scanner)
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        info.map { Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }
    }

    /// `cm`: concatenate the operand matrix onto the tracked CTM.
    /// (Operands pop in reverse: f e d c b a.)
    private static let cmCallback: CGPDFOperatorCallback = { scanner, info in
        var values: [CGFloat] = []
        for _ in 0..<6 {
            var v: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &v) { values.append(CGFloat(v)) }
        }
        guard values.count == 6, let state = state(info) else { return }
        let m = CGAffineTransform(a: values[5], b: values[4], c: values[3],
                                   d: values[2], tx: values[1], ty: values[0])
        state.ctm = m.concatenating(state.ctm)
    }

    private static let saveCallback: CGPDFOperatorCallback = { _, info in
        guard let state = state(info) else { return }
        state.stack.append(state.ctm)
    }

    private static let restoreCallback: CGPDFOperatorCallback = { _, info in
        guard let state = state(info), let top = state.stack.popLast() else { return }
        state.ctm = top
    }

    /// `Do`: image XObjects cover the unit square mapped through the current
    /// CTM (times the optional /Matrix). Form XObjects are descended into.
    private static let doCallback: CGPDFOperatorCallback = { scanner, info in
        guard let state = state(info) else { return }
        var namePointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &namePointer), let name = namePointer else { return }
        let contentStream = CGPDFScannerGetContentStream(scanner)
        let resourceName = String(cString: name)
        guard let resource = CGPDFContentStreamGetResource(contentStream, "XObject", resourceName) else { return }

        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(resource, .stream, &stream), let pdfStream = stream,
              let dictionary = CGPDFStreamGetDictionary(pdfStream) else { return }

        var subtypePointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer), let subtype = subtypePointer else { return }
        switch String(cString: subtype) {
        case "Image":
            recordImage(state: state, dictionary: dictionary)
        case "Form":
            // Nested form: scan its content stream with the shared CTM state.
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let res = resources {
                scanNestedForm(pdfStream, resources: res, parent: contentStream, state: state)
            } else {
                // No /Resources entry: use the form's own dictionary so the
                // resource lookup has a valid (empty) starting point.
                scanNestedForm(pdfStream, resources: dictionary, parent: contentStream, state: state)
            }
        default:
            break
        }
    }

    /// Descends into a Form XObject, sharing the CTM state.
    private static func scanNestedForm(_ form: CGPDFStreamRef,
                                       resources: CGPDFDictionaryRef,
                                       parent: CGPDFContentStreamRef,
                                       state: ScanState) {
        let nested = CGPDFContentStreamCreateWithStream(form, resources, parent)
        defer { CGPDFContentStreamRelease(nested) }
        PageImageAnalyzer().scan(contentStream: nested,
                                  statePointer: Unmanaged.passUnretained(state).toOpaque())
    }

    /// `BI`: inline images are drawn into the unit square through the CTM as well.
    private static let inlineImageCallback: CGPDFOperatorCallback = { _, info in
        guard let state = state(info) else { return }
        recordImage(state: state, dictionary: nil)
    }

    /// Coverage of the image currently being drawn: |det(CTM × Matrix)| / pageArea.
    private static func recordImage(state: ScanState, dictionary: CGPDFDictionaryRef?) {
        var matrixDeterminant = 1.0
        if let dictionary {
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let pdfArray = array,
               CGPDFArrayGetCount(pdfArray) == 6 {
                var values: [CGFloat] = []
                for i in 0..<6 {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(pdfArray, i, &v) { values.append(CGFloat(v)) }
                }
                if values.count == 6 {
                    matrixDeterminant = abs(Double(values[0] * values[3] - values[1] * values[2]))
                }
            }
        }
        let ctm = state.ctm
        let area = abs(Double(ctm.a * ctm.d - ctm.b * ctm.c)) * matrixDeterminant
        state.maxFraction = max(state.maxFraction, area / state.pageArea)
    }

    /// Mutable scanner state shared across operator callbacks.
    final class ScanState {
        var ctm: CGAffineTransform = .identity
        var stack: [CGAffineTransform] = []
        var formDepth = 0
        var maxFraction = 0.0
        let pageArea: Double
        init(pageArea: Double) { self.pageArea = pageArea }
    }
}
