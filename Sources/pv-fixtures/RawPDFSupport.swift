import Foundation

// MARK: - Regex helper (on NSString; UTF-16 offsets)

func firstMatch(_ pattern: String, in s: NSString) -> NSTextCheckingResult? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    return re.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length))
}

func allMatches(_ pattern: String, in s: NSString) -> [NSTextCheckingResult] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s as String, range: NSRange(location: 0, length: s.length))
}

func group(_ s: NSString, _ m: NSTextCheckingResult, _ i: Int) -> String {
    guard i <= m.numberOfRanges else { return "" }
    return s.substring(with: m.range(at: i))
}

// MARK: - Minimal raw-PDF support

/// Object scanning and standards-compliant incremental updates. The whole file
/// is decoded as ISO Latin 1 (byte-preserving), so every UTF-16 location maps
/// 1:1 to a byte offset.
struct RawPDF {
    struct Object {
        let number: Int
        let headerOffset: Int   // byte offset of "N G obj"
        let bodyStart: Int      // first byte of the body
        let bodyEnd: Int        // one past the last body byte
    }

    let data: Data
    let string: NSString      // ISO Latin 1; UTF-16 location == byte offset
    let objects: [Int: Object]
    let trailerSize: Int
    let rootNumber: Int
    let startXRefOffset: Int
    let oldTrailerID: String?  // raw "/ID [ ... ]" substring if present
    let infoNumber: Int?       // /Info object number from the trailer, if any

    static func parse(_ data: Data) -> RawPDF? {
        guard let s = NSString(data: data, encoding: NSISOLatin1StringEncoding) else { return nil }

        // All indirect object headers.
        var objects: [Int: Object] = [:]
        for m in allMatches("(\\d+)\\s+(\\d+)\\s+obj\\b", in: s) {
            let number = Int(group(s, m, 1))!
            // Body ends at the next "endobj".
            var bodyEnd = s.length
            let from = m.range.location + m.range.length
            let e = s.range(of: "endobj", range: NSRange(location: from, length: s.length - from))
            if e.location != NSNotFound { bodyEnd = e.location }
            var bs = from
            while bs < bodyEnd, [0x20, 0x0A, 0x0D].contains(s.character(at: bs)) { bs += 1 }
            var be = bodyEnd
            while be > bs, [0x0A, 0x0D].contains(s.character(at: be - 1)) { be -= 1 }
            objects[number] = Object(number: number, headerOffset: m.range.location,
                                      bodyStart: bs, bodyEnd: be)
        }
        guard !objects.isEmpty else { return nil }

        // startxref at the end.
        var startXRef = -1
        let r = s.range(of: "startxref", options: .backwards, range: NSRange(location: 0, length: s.length))
        if r.location != NSNotFound {
            let rest = s.substring(from: r.location + r.length)
            let digits = rest.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " }).first ?? ""
            startXRef = Int(digits) ?? -1
        }
        guard startXRef >= 0 else { return nil }

        // Trailer dict (classic table) or xref stream dict.
        var dictStart = -1
        let t = s.range(of: "trailer", options: .backwards, range: NSRange(location: 0, length: s.length))
        if t.location != NSNotFound {
            dictStart = t.location
        } else if let obj = objects.values.first(where: { obj in
            let snippet = s.substring(with: NSRange(location: obj.headerOffset,
                                                    length: min(256, s.length - obj.headerOffset)))
            return firstMatch("/Type\\s*/XRef", in: snippet as NSString) != nil
        }) {
            dictStart = obj.headerOffset
        }
        guard dictStart >= 0 else { return nil }
        let dictNS = s as NSString
        let dictText = dictNS.substring(with: NSRange(location: dictStart, length: min(2048, s.length - dictStart))) as NSString
        var size = 0, root = 0
        if let m = firstMatch("/Size\\s+(\\d+)", in: dictText) { size = Int(group(dictText, m, 1)) ?? 0 }
        if let m = firstMatch("/Root\\s+(\\d+)", in: dictText) { root = Int(group(dictText, m, 1)) ?? 0 }
        var id: String?
        if let m = firstMatch("/ID\\s*\\[[^\\]]*\\]", in: dictText) { id = group(dictText, m, 0) }
        var info: Int?
        if let m = firstMatch("/Info\\s+(\\d+)", in: dictText) { info = Int(group(dictText, m, 1)) }
        guard size > 0, root > 0, objects[root] != nil else { return nil }

        return RawPDF(data: data, string: s, objects: objects, trailerSize: size,
                      rootNumber: root, startXRefOffset: startXRef, oldTrailerID: id,
                      infoNumber: info)
    }

    /// Body of an object as latin-1 string.
    func body(of number: Int) -> String {
        guard let o = objects[number] else { return "" }
        let ns = string as NSString
        return ns.substring(with: NSRange(location: o.bodyStart, length: o.bodyEnd - o.bodyStart))
    }

    /// Page object numbers in document order (via the /Pages tree kids).
    func pageObjectNumbers() -> [Int] {
        for o in objects.values.sorted(by: { $0.headerOffset < $1.headerOffset }) {
            let snippet = string.substring(with: NSRange(location: o.headerOffset,
                                                         length: min(2048, string.length - o.headerOffset))) as NSString
            guard firstMatch("/Type\\s*/Pages\\b", in: snippet) != nil,
                  let kids = firstMatch("/Kids\\s*\\[([^\\]]*)\\]", in: snippet) else { continue }
            let kidText = group(snippet, kids, 1) as NSString
            return allMatches("(\\d+)\\s+\\d+\\s+R", in: kidText).compactMap { Int(group(kidText, $0, 1)) }
        }
        return []
    }

    /// A new object body with `entry` inserted right after the opening `<<`.
    static func inserting(_ entry: String, atDictStartOf body: String) -> String {
        guard let r = body.range(of: "<<") else { return body }
        return String(body[..<r.upperBound]) + " " + entry + String(body[r.upperBound...])
    }

    /// A new object body with `entry` inserted after the pattern.
    static func inserting(_ entry: String, after pattern: String, in body: String) -> String? {
        guard let r = body.range(of: pattern, options: .regularExpression) else { return nil }
        return String(body[..<r.upperBound]) + " " + entry + String(body[r.upperBound...])
    }
}

// MARK: - Incremental update

enum RawPDFWriter {
    /// Appends a standards-compliant incremental update to the PDF at `url`:
    /// rewrites the objects in `updated` (same numbers) and appends `added`
    /// (numbers allocated sequentially, starting at the first free number).
    @discardableResult
    static func appendIncrementalUpdate(to url: URL,
                                        updated: [(number: Int, body: Data)] = [],
                                        added: [Data]) throws -> [Int] {
        let original = try Data(contentsOf: url)
        guard let pdf = RawPDF.parse(original) else {
            throw FixtureError.writeFailed("PDF konnte für inkrementelles Update nicht geparst werden: \(url.path)")
        }

        let maxNumber = pdf.objects.keys.max() ?? 0
        var nextNumber = max(pdf.trailerSize, maxNumber + 1)
        var newNumbers: [Int] = []
        for _ in added { newNumbers.append(nextNumber); nextNumber += 1 }

        var out = original
        var offsets: [(number: Int, offset: Int)] = []

        func writeStr(_ s: String) { out.append(contentsOf: s.utf8) }

        for u in updated.sorted(by: { $0.number < $1.number }) {
            offsets.append((u.number, out.count))
            writeStr("\(u.number) 0 obj\n")
            out.append(u.body)
            writeStr("\nendobj\n")
        }
        for (i, body) in added.enumerated() {
            offsets.append((newNumbers[i], out.count))
            writeStr("\(newNumbers[i]) 0 obj\n")
            out.append(body)
            writeStr("\nendobj\n")
        }

        // New xref section (grouped into contiguous subsections).
        let xrefOffset = out.count
        writeStr("xref\n")
        var run: [(number: Int, offset: Int)] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            writeStr("\(run.first!.number) \(run.count)\n")
            for e in run { writeStr(String(format: "%010d 00000 n\n", e.offset)) }
            run.removeAll()
        }
        for e in offsets.sorted(by: { $0.number < $1.number }) {
            if let last = run.last, last.number + 1 == e.number {
                run.append(e)
            } else {
                flushRun()
                run = [e]
            }
        }
        flushRun()

        // Trailer.
        let newSize = pdf.trailerSize + added.count
        writeStr("trailer\n<< /Size \(newSize) /Root \(pdf.rootNumber) 0 R")
        if let info = pdf.infoNumber { writeStr(" /Info \(info) 0 R") }
        if let id = pdf.oldTrailerID { writeStr(" \(id)") }
        writeStr(" /Prev \(pdf.startXRefOffset) >>\nstartxref\n\(xrefOffset)\n%%EOF\n")

        try out.write(to: url, options: .atomic)
        return newNumbers
    }

    /// Inserts `/Rotate <deg>` into the page object dictionary body.
    static func updatePageRotation(in body: String, degrees: Int) -> Data? {
        RawPDF.inserting("/Rotate \(degrees)", after: "/Type\\s*/Page\\b", in: body)
            .map { Data($0.utf8) }
    }

    /// Inserts `/CropBox [x y w h]` into the page object dictionary body.
    static func updatePageCropBox(in body: String, crop: CGRect) -> Data? {
        let entry = String(format: "/CropBox [%.2f %.2f %.2f %.2f]",
                           crop.origin.x, crop.origin.y, crop.width, crop.height)
        return RawPDF.inserting(entry, after: "/Type\\s*/Page\\b", in: body)
            .map { Data($0.utf8) }
    }

    /// Truncates the file to `fraction` of its bytes (damaged PDF fixture).
    static func truncate(_ url: URL, fraction: Double) throws -> (originalBytes: Int, truncatedBytes: Int) {
        let data = try Data(contentsOf: url)
        let cut = Int(Double(data.count) * fraction)
        try data.prefix(cut).write(to: url)
        return (data.count, cut)
    }
}
