import Foundation
import Compression

/// A parsed PDF object. Used only for structural inspection (catalog, pages,
/// info dictionary, name trees) — never to interpret page content.
indirect enum PDFVal {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case string(String)
    case name(String)
    case array([PDFVal])
    case dict([String: PDFVal])
    case ref(Int)
    case stream(header: [String: PDFVal], data: Data)
}

extension PDFVal {
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .real(let d): return Int(d)
        default: return nil
        }
    }
    var nameValue: String? { if case .name(let s) = self { return s }; return nil }
    var dictValue: [String: PDFVal]? { if case .dict(let d) = self { return d }; return nil }
    var arrayValue: [PDFVal]? { if case .array(let a) = self { return a }; return nil }

    /// Best-effort string rendering for reports (info dictionary values).
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .name(let s): return s
        case .int(let i): return String(i)
        case .real(let d): return String(d)
        case .bool(let b): return String(b)
        case .array(let a): return a.compactMap(\.stringValue).joined(separator: " ")
        default: return nil
        }
    }
}

/// Best-effort raw PDF structure reader.
///
/// It finds indirect objects by scanning for `num gen obj` headers (and by
/// inflating `/ObjStm` object streams), then reads the trailer / xref stream
/// dictionary and walks the page tree. It does not need a functioning xref
/// parser, but it can therefore also be fooled by a deliberately hostile
/// file; callers treat "could not fully parse" as a failure, never as a pass.
struct PDFStructure {
    private(set) var objects: [Int: PDFVal] = [:]
    private(set) var catalog: [String: PDFVal]?
    private(set) var trailerDict: [String: PDFVal]?
    private(set) var info: [String: PDFVal]?
    /// Page dictionaries in document order (each `["Type"] == "Page"`).
    private(set) var pages: [[String: PDFVal]] = []
    /// Effective /Resources for each page (own or inherited from /Pages).
    private(set) var pageResources: [[String: PDFVal]] = []
    /// True when catalog and page tree were found.
    private(set) var parsingComplete = false
    private(set) var notes: [String] = []

    // MARK: Derived facts

    var catalogKeys: [String] { catalog?.keys.sorted() ?? [] }

    var infoDictionary: [String: String] {
        (info ?? [:]).compactMapValues(\.stringValue)
    }

    var hasForm: Bool { catalog?["AcroForm"] != nil }

    var hasEmbeddedFiles: Bool {
        if catalog?["AF"] != nil { return true }
        guard let names = resolve(catalog?["Names"])?.dictValue else { return false }
        return names["EmbeddedFiles"] != nil
    }

    var hasOpenAction: Bool { catalog?["OpenAction"] != nil || catalog?["AA"] != nil }

    var hasOutlines: Bool { catalog?["Outlines"] != nil }

    var hasJavaScript: Bool { catalog?["JavaScript"] != nil || catalog?["AA"] != nil }

    var isEncrypted: Bool { trailerDict?["Encrypt"] != nil }

    var annotationCount: Int {
        pages.reduce(0) { $0 + (resolve($1["Annots"])?.arrayValue?.count ?? 0) }
    }

    var perPageImageCount: [Int] {
        zip(pages, pageResources).map { page, resources in
            guard let xobjects = resolve(resources["XObject"])?.dictValue else { return 0 }
            return xobjects.values.filter { value in
                if case .stream(let header, _)? = resolve(value) {
                    return header["Subtype"]?.nameValue == "Image"
                }
                return false
            }.count
        }
    }

    /// Resolves an indirect reference (one level of recursion at a time, capped).
    func resolve(_ value: PDFVal?, depth: Int = 0) -> PDFVal? {
        guard depth < 10, let value else { return nil }
        if case .ref(let n) = value { return resolve(objects[n], depth: depth + 1) }
        return value
    }

    // MARK: Parsing

    static func parse(data: Data) -> PDFStructure {
        var s = PDFStructure()
        let b = [UInt8](data)
        guard b.count > 8 else { return s }

        // 1. Indirect objects with plain headers ("n g obj ... endobj").
        var cursor = 0
        while let header = nextObjectHeader(b, from: cursor) {
            let p = PDFByteParser(bytes: b, position: header.bodyOffset)
            guard let value = p.parseValue() else { cursor = header.bodyOffset; continue }
            let keyword = p.keywordAfterWhitespace()
            if keyword == "stream", case .dict(let headerDict) = value,
               let stream = p.streamDataAfterDict() {
                s.objects[header.number] = .stream(header: headerDict, data: stream.data)
                cursor = stream.nextOffset
            } else {
                s.objects[header.number] = value
                cursor = keyword == "endobj" ? p.position : header.bodyOffset + 1
            }
        }

        // 2. Objects compressed inside /ObjStm object streams.
        s.inflateObjectStreams()

        // 3. Trailer (classic trailer dict, or xref stream dict), then catalog and info.
        s.trailerDict = s.findTrailer(in: b)
        if let root = s.resolve(s.trailerDict?["Root"]), let cd = root.dictValue {
            s.catalog = cd
        } else if let found = s.objects.values.compactMap(\.dictValue)
            .first(where: { $0["Type"]?.nameValue == "Catalog" }) {
            s.catalog = found
        }
        if let infoVal = s.resolve(s.trailerDict?["Info"])?.dictValue {
            s.info = infoVal
        }

        // 4. Page tree.
        if let pagesVal = s.resolve(s.catalog?["Pages"])?.dictValue {
            s.walkPages(node: pagesVal, inheritedResources: nil, depth: 0)
        }
        s.parsingComplete = s.catalog != nil
        return s
    }

    // MARK: Private parts

    private mutating func inflateObjectStreams() {
        let streams = objects.filter { _, v in
            if case .stream(let h, _) = v { return h["Type"]?.nameValue == "ObjStm" }
            return false
        }
        for (_, value) in streams {
            guard case .stream(let h, let d) = value,
                  let n = h["N"]?.intValue, let first = h["First"]?.intValue, n > 0
            else { continue }
            let filter = h["Filter"]
            let flate: Bool
            switch filter {
            case .none, .name("None"): flate = false
            case .name("FlateDecode"): flate = true
            case .array(let arr) where arr.contains(where: { $0.nameValue == "FlateDecode" }): flate = true
            default:
                notes.append("Objektstrom mit nicht unterstützttem Filter")
                continue
            }
            let decoded: [UInt8]
            if flate {
                guard let unzipped = PDFStructure.inflate(d) else {
                    notes.append("Objektstrom konnte nicht dekomprimiert werden")
                    continue
                }
                decoded = unzipped
            } else {
                decoded = [UInt8](d)
            }
            let p = PDFByteParser(bytes: decoded, position: 0)
            var nums: [Int] = []
            var offsets: [Int] = []
            for _ in 0..<n {
                guard let num = p.readIntToken(), let offset = p.readIntToken() else { break }
                nums.append(num)
                offsets.append(offset)
            }
            guard nums.count == n, offsets.count == n else {
                notes.append("Objektstrom-Header unvollständig")
                continue
            }
            for k in 0..<n where objects[nums[k]] == nil {
                p.position = min(first + offsets[k], decoded.count)
                if let v = p.parseValue() { objects[nums[k]] = v }
            }
        }
    }

    /// Raw DEFLATE (RFC 1951) via the Compression framework; strips a zlib
    /// wrapper (RFC 1950) when present.
    static func inflate(_ data: Data) -> [UInt8]? {
        var raw = data
        if raw.count > 6 {
            let h0 = Int(raw[raw.startIndex])
            let h1 = Int(raw[raw.index(after: raw.startIndex)])
            if (h0 & 0x0F) == 8 && ((h0 << 8) | h1) % 31 == 0 {
                raw = raw.dropFirst(2).dropLast(4)
            }
        }
        return raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> [UInt8]? in
            guard let base = src.baseAddress, src.count > 0 else { return nil }
            var capacity = max(64, src.count * 8)
            while capacity <= 1 << 30 {
                var dst = [UInt8](repeating: 0, count: capacity)
                let written = dst.withUnsafeMutableBytes { dstPtr in
                    compression_decode_buffer(
                        dstPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        base.assumingMemoryBound(to: UInt8.self), src.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
                if written < capacity { return Array(dst[0..<written]) }
                capacity *= 2
            }
            return nil
        }
    }

    private func findTrailer(in b: [UInt8]) -> [String: PDFVal]? {
        // Classic trailer: last "trailer" keyword followed by a dict.
        var searchStart = 0
        var last: [String: PDFVal]?
        while let r = PDFStructure.findSequence(b, "trailer", from: searchStart) {
            searchStart = r.lowerBound + 7
            let p = PDFByteParser(bytes: b, position: r.lowerBound + 7)
            if let v = p.parseValue(), let d = v.dictValue { last = d }
        }
        if let last { return last }
        // Xref stream variant: its dictionary carries /Root and /Info.
        for (_, v) in objects.reversed() {
            if case .stream(let h, _) = v, h["Type"]?.nameValue == "XRef", h["Root"] != nil {
                return h
            }
        }
        return nil
    }

    private mutating func walkPages(node: [String: PDFVal], inheritedResources: [String: PDFVal]?, depth: Int) {
        guard depth < 32 else { return }
        let resources = resolve(node["Resources"])?.dictValue ?? inheritedResources
        guard let kids = resolve(node["Kids"])?.arrayValue else {
            // A leaf without /Kids: some minimal PDFs omit /Type on pages.
            pages.append(node)
            pageResources.append(resources ?? [:])
            return
        }
        for kid in kids {
            guard let kd = resolve(kid)?.dictValue else { continue }
            if kd["Kids"] != nil {
                walkPages(node: kd, inheritedResources: resources, depth: depth + 1)
            } else if kd["Type"]?.nameValue == "Page" || kd["Contents"] != nil {
                pages.append(kd)
                pageResources.append(resolve(kd["Resources"])?.dictValue ?? resources ?? [:])
            }
        }
    }

    private static func nextObjectHeader(_ b: [UInt8], from start: Int) -> (number: Int, bodyOffset: Int)? {
        var searchFrom = start
        while let r = findSequence(b, "obj", from: searchFrom) {
            searchFrom = r.lowerBound + 1
            let j = r.lowerBound
            // "endobj" does not match (no whitespace before "obj"); require the
            // full "num gen obj" header.
            guard j > 2, isWhitespace(b[j - 1]),
                  let (genStart, _) = trailingDigits(b, before: j - 1),
                  genStart > 0, isWhitespace(b[genStart - 1]),
                  let (numStart, num) = trailingDigits(b, before: genStart - 1),
                  numStart > 0, isWhitespace(b[numStart - 1])
            else { continue }
            var body = j + 3
            while body < b.count, isWhitespace(b[body]) { body += 1 }
            return (num, body)
        }
        return nil
    }

    private static func trailingDigits(_ b: [UInt8], before e: Int) -> (start: Int, value: Int)? {
        var s = e
        while s > 0, b[s - 1] >= 0x30, b[s - 1] <= 0x39 { s -= 1 }
        guard s < e, let v = Int(String(bytes: b[s..<e], encoding: .ascii) ?? "") else { return nil }
        return (s, v)
    }

    static func findSequence(_ b: [UInt8], _ pattern: String, from start: Int) -> Range<Int>? {
        let p = [UInt8](pattern.utf8)
        guard !p.isEmpty, b.count >= p.count else { return nil }
        var i = max(0, start)
        while i <= b.count - p.count {
            if b[i] == p[0] {
                var match = true
                for k in 1..<p.count where b[i + k] != p[k] { match = false; break }
                if match { return i..<(i + p.count) }
            }
            i += 1
        }
        return nil
    }

    static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x00
    }
}

/// Byte-level PDF object parser.
final class PDFByteParser {
    private(set) var pos: Int
    private let b: [UInt8]

    init(bytes: [UInt8], position: Int) {
        b = bytes
        pos = min(max(position, 0), bytes.count)
    }

    var position: Int {
        get { pos }
        set { pos = min(max(newValue, 0), b.count) }
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "<")
            || c == UInt8(ascii: ">") || c == UInt8(ascii: "[") || c == UInt8(ascii: "]")
            || c == UInt8(ascii: "{") || c == UInt8(ascii: "}") || c == UInt8(ascii: "/")
            || c == UInt8(ascii: "%")
    }

    private static func isRegular(_ c: UInt8) -> Bool {
        !PDFStructure.isWhitespace(c) && !isDelimiter(c)
    }

    func skipWhitespace() {
        while pos < b.count {
            let c = b[pos]
            if c == UInt8(ascii: "%") {
                repeat { pos += 1 } while pos < b.count && b[pos] != 0x0A && b[pos] != 0x0D
            } else if PDFStructure.isWhitespace(c) {
                pos += 1
            } else {
                break
            }
        }
    }

    func peek() -> UInt8? { pos < b.count ? b[pos] : nil }

    /// Reads a bare keyword (e.g. `endobj`, `R`, `stream`). Does not skip
    /// leading whitespace.
    private func readBareWord() -> String {
        var end = pos
        while end < b.count, Self.isRegular(b[end]) { end += 1 }
        let s = String(bytes: b[pos..<end], encoding: .ascii) ?? ""
        pos = end
        return s
    }

    /// Skips whitespace and reads the next keyword ("" at end of data).
    func keywordAfterWhitespace() -> String {
        skipWhitespace()
        return readBareWord()
    }

    func parseValue() -> PDFVal? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        switch c {
        case UInt8(ascii: "<"):
            if pos + 1 < b.count, b[pos + 1] == UInt8(ascii: "<") { return parseDict() }
            return parseHexString()
        case UInt8(ascii: "("):
            return parseLiteralString()
        case UInt8(ascii: "["):
            return parseArray()
        case UInt8(ascii: "/"):
            return .name(readName() ?? "")
        default:
            if c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                || (c >= 0x30 && c <= 0x39) {
                return parseNumberOrRef()
            }
            switch readBareWord() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return nil
            }
        }
    }

    private func parseDict() -> PDFVal? {
        pos += 2
        var d: [String: PDFVal] = [:]
        while true {
            skipWhitespace()
            guard pos < b.count else { return nil }
            if b[pos] == UInt8(ascii: ">") {
                guard pos + 1 < b.count, b[pos + 1] == UInt8(ascii: ">") else { return nil }
                pos += 2
                return .dict(d)
            }
            guard b[pos] == UInt8(ascii: "/"), let key = readName() else { return nil }
            guard let value = parseValue() else { return nil }
            d[key] = value
        }
    }

    private func parseArray() -> PDFVal? {
        pos += 1
        var a: [PDFVal] = []
        while true {
            skipWhitespace()
            guard pos < b.count else { return nil }
            if b[pos] == UInt8(ascii: "]") { pos += 1; return .array(a) }
            guard let v = parseValue() else { return nil }
            a.append(v)
        }
    }

    private func readName() -> String? {
        pos += 1 // '/'
        var out: [UInt8] = []
        while pos < b.count {
            let c = b[pos]
            if c == UInt8(ascii: "#"), pos + 2 < b.count,
               let hi = hexValue(b[pos + 1]), let lo = hexValue(b[pos + 2]) {
                out.append((hi << 4) | lo)
                pos += 3
            } else if Self.isRegular(c) {
                out.append(c)
                pos += 1
            } else {
                break
            }
        }
        return String(bytes: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
    }

    private func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private func parseLiteralString() -> PDFVal? {
        pos += 1 // '('
        var out: [UInt8] = []
        var depth = 1
        while pos < b.count {
            let c = b[pos]
            if c == 0x5C { // backslash
                pos += 1
                guard pos < b.count else { break }
                let e = b[pos]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A); pos += 1
                case UInt8(ascii: "r"): out.append(0x0D); pos += 1
                case UInt8(ascii: "t"): out.append(0x09); pos += 1
                case UInt8(ascii: "b"): out.append(0x08); pos += 1
                case UInt8(ascii: "f"): out.append(0x0C); pos += 1
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"): out.append(e); pos += 1
                case 0x0D:
                    pos += 1
                    if pos < b.count, b[pos] == 0x0A { pos += 1 }
                case 0x0A: pos += 1
                default:
                    if e >= 0x30 && e <= 0x37 {
                        var v = 0
                        var digits = 0
                        while pos < b.count, digits < 3, b[pos] >= 0x30, b[pos] <= 0x37 {
                            v = v * 8 + Int(b[pos] - 0x30)
                            pos += 1
                            digits += 1
                        }
                        out.append(UInt8(v & 0xFF))
                    } else {
                        out.append(e)
                        pos += 1
                    }
                }
            } else if c == UInt8(ascii: "(") {
                depth += 1
                out.append(c)
                pos += 1
            } else if c == UInt8(ascii: ")") {
                depth -= 1
                pos += 1
                if depth == 0 { return .string(Self.decode(out)) }
            } else if c == 0x0D {
                out.append(0x0A)
                pos += 1
                if pos < b.count, b[pos] == 0x0A { pos += 1 }
            } else {
                out.append(c)
                pos += 1
            }
        }
        return .string(Self.decode(out))
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private func parseHexString() -> PDFVal? {
        pos += 1 // '<'
        var nibbles: [UInt8] = []
        while pos < b.count {
            let c = b[pos]
            if c == UInt8(ascii: ">") { pos += 1; break }
            if let v = hexValue(c) { nibbles.append(v) } else if !PDFStructure.isWhitespace(c) && c != 0 {
                return nil
            }
            pos += 1
        }
        var out: [UInt8] = []
        var i = 0
        while i < nibbles.count {
            let hi = nibbles[i]
            let lo = i + 1 < nibbles.count ? nibbles[i + 1] : 0
            out.append((hi << 4) | lo)
            i += 2
        }
        return .string(Self.decode(out))
    }

    private func parseNumberOrRef() -> PDFVal? {
        var end = pos
        while end < b.count {
            let c = b[end]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                || c == UInt8(ascii: ".") {
                end += 1
            } else {
                break
            }
        }
        guard end > pos else { return nil }
        let token = String(bytes: b[pos..<end], encoding: .ascii) ?? ""
        // Indirect reference lookahead: "num gen R".
        if let first = Int(token) {
            var p = end
            while p < b.count, PDFStructure.isWhitespace(b[p]) { p += 1 }
            if let (genEnd, gen) = scanInt(at: p), gen >= 0 {
                var q = genEnd
                while q < b.count, PDFStructure.isWhitespace(b[q]) { q += 1 }
                if q < b.count, b[q] == UInt8(ascii: "R"),
                   q + 1 == b.count || !Self.isRegular(b[q + 1]) {
                    pos = q + 1
                    return .ref(first)
                }
            }
        }
        pos = end
        if let i = Int(token) { return .int(i) }
        if let d = Double(token) { return .real(d) }
        return nil
    }

    func readIntToken() -> Int? {
        skipWhitespace()
        guard let (end, v) = scanInt(at: pos) else { return nil }
        pos = end
        return v
    }

    private func scanInt(at start: Int) -> (end: Int, value: Int)? {
        var e = start
        while e < b.count, b[e] >= 0x30, b[e] <= 0x39 { e += 1 }
        guard e > start, let v = Int(String(bytes: b[start..<e], encoding: .ascii) ?? "") else {
            return nil
        }
        return (e, v)
    }

    /// After a dict parsed at object level: expects the `stream` keyword to
    /// have been consumed already; skips the EOL and returns the raw stream
    /// data up to `endstream`, plus the offset to continue scanning from.
    func streamDataAfterDict() -> (data: Data, nextOffset: Int)? {
        // EOL after "stream": CR, LF or CRLF.
        if peek() == 0x0D {
            pos += 1
            if peek() == 0x0A { pos += 1 }
        } else if peek() == 0x0A {
            pos += 1
        }
        guard pos < b.count else { return nil }
        let dataStart = pos
        let end = PDFStructure.findSequence(b, "endstream", from: dataStart)?.lowerBound ?? b.count
        return (Data(b[dataStart..<end]), min(end + 9, b.count))
    }
}
