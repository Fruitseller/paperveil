import CoreML
import CoreGraphics
import Foundation
import PDFKit
import PaperVeilCore
import Vision

/// OCR of a rendered PDF page using Apple Vision (newest Swift API,
/// `RecognizeTextRequest`, revision 3). German is the primary recognition
/// language; language correction is OFF so identifiers, dates and numbers are
/// not silently "corrected".
///
/// The page is rendered as it is *displayed* (honouring /Rotate and the crop box)
/// at ~300 dpi; every recognized word box is mapped back into *unrotated page
/// space* (the coordinate system of `PDFPage.bounds(for: .mediaBox)`), handling
/// rotations 0/90/180/270 and crop-box offsets.
public struct OCRExtractor: Sendable {
    /// Rendering target: 300 dpi like a typical scan.
    private static let targetDPI: CGFloat = 300
    /// Upper bound for bitmap edges (keeps memory bounded on huge pages;
    /// effectively still ≥ ~430 dpi on A3 pages).
    private static let maxPixelEdge: CGFloat = 5000
    /// Minimum confidence for an OCR word to be considered certain.
    public static let lowConfidenceThreshold = 0.5

    public init() {}

    /// Recognizes words on one page. Returns [] when Vision finds no text.
    /// `pageIndex` is only recorded in the words, not used for recognition.
    public func extractWords(page: PDFPage, pageIndex: Int) async throws -> [TextWord] {
        let geometry = PageGeometry(crop: page.bounds(for: .cropBox), rotation: page.rotation)
        let (image, pixelSize, scale) = renderDisplayed(page: page, geometry: geometry)

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [
            Locale.Language(identifier: "de-DE"),
            Locale.Language(identifier: "en-US"),
        ]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false

        let observations = try await OCRCompute.perform(request, on: image)

        // Collect line data first (normalized, displayed space), then bring the
        // lines into reading order before assigning line numbers.
        struct OCRLine {
            var normalizedRect: CGRect
            var words: [(text: String, normalizedRect: CGRect)] = []
            var confidence: Double = 1
        }
        var lines: [OCRLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let lineRect = Self.normalizedRect(fromQuad: [observation.topLeft, observation.topRight,
                                                           observation.bottomRight, observation.bottomLeft])
            var line = OCRLine(normalizedRect: lineRect)
            line.confidence = Double(candidate.confidence).clamped(to: 0...1)
            line.words = Self.words(in: candidate, lineRect: lineRect)
            guard !line.words.isEmpty else { continue }
            lines.append(line)
        }

        // Reading order in displayed space: top lines first, left before right.
        lines.sort { (-$0.normalizedRect.midY, $0.normalizedRect.minX) < (-$1.normalizedRect.midY, $1.normalizedRect.minX) }

        var result: [TextWord] = []
        for (lineNumber, line) in lines.enumerated() {
            for word in line.words {
                let pageRect = geometry.pageRect(
                    fromNormalizedRect: word.normalizedRect,
                    imagePixelSize: pixelSize,
                    scale: scale
                )
                result.append(TextWord(
                    text: word.text,
                    rect: PageRect(pageRect),
                    source: .ocr,
                    confidence: line.confidence,
                    line: lineNumber
                ))
            }
        }
        return result
    }

    // MARK: - Rendering

    /// Renders the page as displayed (rotation + crop box) into an RGB bitmap.
    private func renderDisplayed(page: PDFPage, geometry: PageGeometry) -> (image: CGImage, pixelSize: CGSize, scale: CGFloat) {
        let displayed = geometry.displayedSize
        var scale = Self.targetDPI / 72
        if scale * max(displayed.width, displayed.height) > Self.maxPixelEdge {
            scale = Self.maxPixelEdge / max(displayed.width, displayed.height)
        }
        let pxW = max(1, Int((displayed.width * scale).rounded()))
        let pxH = max(1, Int((displayed.height * scale).rounded()))

        let context = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)

        return (context.makeImage()!, CGSize(width: pxW, height: pxH), scale)
    }

    // MARK: - Word geometry

    /// Splits a recognized line candidate into words and determines per-word
    /// boxes. Prefers Vision's exact per-word boxes (`boundingBox(for:)`, which
    /// works with language correction disabled on the current request revision);
    /// if a word has no box, its extent is estimated proportionally inside the
    /// line box so no word is lost.
    static func words(in candidate: RecognizedText, lineRect: CGRect) -> [(text: String, normalizedRect: CGRect)] {
        let string = candidate.string
        var result: [(String, CGRect)] = []
        var index = string.startIndex
        while index < string.endIndex {
            while index < string.endIndex, string[index].isWhitespace { index = string.index(after: index) }
            guard index < string.endIndex else { break }
            let start = index
            while index < string.endIndex, !string[index].isWhitespace { index = string.index(after: index) }
            let wordRange = start..<index
            let text = String(string[wordRange])

            var rect: CGRect
            if let box = candidate.boundingBox(for: wordRange),
               let exact = normalizedQuad(of: box) {
                rect = exact
            } else {
                rect = Self.estimatedRect(of: wordRange, in: string, lineRect: lineRect)
            }
            result.append((text, rect))
        }
        return result
    }

    /// Axis-aligned rect around a Vision quadrilateral (normalized coordinates).
    private static func normalizedRect(fromQuad points: [NormalizedPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func normalizedQuad(of box: RectangleObservation) -> CGRect? {
        let rect = normalizedRect(fromQuad: [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft])
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Fallback: estimate a word's box proportionally inside the line box,
    /// based on UTF-16 offsets. Approximate, but only used when Vision does not
    /// provide an exact word box.
    static func estimatedRect(of range: Range<String.Index>, in string: String, lineRect: CGRect) -> CGRect {
        let total = Double(string.utf16.count)
        guard total > 0 else { return lineRect }
        let start = Double(string.utf16.distance(from: string.startIndex, to: range.lowerBound))
        let end = Double(string.utf16.distance(from: string.startIndex, to: range.upperBound))
        return CGRect(
            x: lineRect.minX + (start / total) * lineRect.width,
            y: lineRect.minY,
            width: max((end - start) / total * lineRect.width, 1.0 / 100),
            height: lineRect.height
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Runs Vision on the default (Neural Engine/GPU) path and falls back to the CPU
/// if that path is unavailable, e.g. in virtualised CI runners without an ANE.
/// `PAPERVEIL_OCR_CPU_ONLY=1` forces the CPU path.
public enum OCRCompute {
    public static func perform(_ request: RecognizeTextRequest, on image: CGImage) async throws -> [RecognizedTextObservation] {
        var attempts: [RecognizeTextRequest] = []
        if ProcessInfo.processInfo.environment["PAPERVEIL_OCR_CPU_ONLY"] != "1" { attempts.append(request) }
        attempts.append(cpuOnly(request))
        var fast = cpuOnly(request)
        fast.recognitionLevel = .fast
        attempts.append(fast)
        var lastError: Error = CancellationError()
        for attempt in attempts {
            do {
                return try await attempt.perform(on: image)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// True if Vision OCR works on this machine at all (probe on a tiny image).
    public static func isAvailable() async -> Bool {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let img = ctx.makeImage() else { return false }
        // Hard timeout: on some virtualised Macs Vision neither returns nor honours cancellation.
        let gate = ProbeGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task.detached {
                let ok = (try? await perform(RecognizeTextRequest(), on: img)) != nil
                if gate.claim() { cont.resume(returning: ok) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if gate.claim() { cont.resume(returning: false) }
            }
        }
    }

    public static let timeoutSeconds: Double = 30

    static func cpuOnly(_ request: RecognizeTextRequest) -> RecognizeTextRequest {
        var r = request
        let cpu = MLComputeDevice.allComputeDevices.first { if case .cpu = $0 { true } else { false } }
        for stage in r.supportedComputeStageDevices.keys { r.setComputeDevice(cpu, for: stage) }
        return r
    }
}

private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
