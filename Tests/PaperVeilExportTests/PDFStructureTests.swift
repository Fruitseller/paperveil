import Compression
import Foundation
import PDFKit
import Testing
@testable import PaperVeilExport

/// Unit tests for the raw PDF structure reader, including objects hidden in
/// /ObjStm object streams behind an xref stream (the format modern producers
/// write — the inspector must not go blind on them).
@Suite struct PDFStructureTests {
    @Test func parsesSourceFixture() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        try TestFixtures.buildSource(source)

        let structure = PDFStructure.parse(data: try Data(contentsOf: source))

        #expect(structure.parsingComplete)
        #expect(structure.catalogKeys.contains("AcroForm"))
        #expect(structure.catalogKeys.contains("Names"))
        #expect(structure.hasForm)
        #expect(structure.hasEmbeddedFiles)
        #expect(structure.pages.count == 5)
        #expect(structure.annotationCount == 3)
        #expect(structure.perPageImageCount == [0, 0, 0, 0, 0])
        #expect(structure.infoDictionary["Title"]?.contains(TestFixtures.marker) == true)
        #expect(structure.infoDictionary["Keywords"]?.contains(TestFixtures.marker) == true)
        #expect(!structure.isEncrypted)
    }

    /// A minimal PDF whose catalog, page and info objects live inside a
    /// Flate-compressed /ObjStm and whose xref is an xref *stream* with
    /// type-2 entries. Both the parser and PDFKit must read it.
    @Test func readsObjectsInsideObjectStreamWithXRefStream() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("objstm.pdf")
        try ObjStmPDF.build(at: url)

        let structure = PDFStructure.parse(data: try Data(contentsOf: url))
        #expect(structure.parsingComplete)
        #expect(structure.catalogKeys.contains("Pages"))
        #expect(structure.pages.count == 1)
        #expect(structure.infoDictionary["Title"] == "Objektstrom-Test")
        #expect(!structure.hasForm)
        #expect(!structure.hasEmbeddedFiles)

        #expect(PDFDocument(url: url)?.pageCount == 1)
    }

    @Test func emptyDataIsIncompleteButHarmless() {
        let structure = PDFStructure.parse(data: Data())
        #expect(!structure.parsingComplete)
        #expect(structure.pages.isEmpty)
        #expect(structure.catalogKeys.isEmpty)
    }
}


/// Builds a minimal single-page PDF: objects 1 (catalog), 3 (page) and 6
/// (info) are compressed inside object stream 7; the cross-reference is an
/// xref stream (object 8) with /W [1 4 2] and type-2 entries.
enum ObjStmPDF {
    static func build(at url: URL) throws {
        let pagesBody = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        let content = Data("10 10 m 100 100 l S".utf8)
        let catalogBody = "<< /Type /Catalog /Pages 2 0 R >>"
        let pageBody = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 5 0 R >>"
        let infoBody = "<< /Title (Objektstrom-Test) >>"

        // ObjStm: header = N object-number/offset pairs, then the objects.
        let header = "1 0 3 \(catalogBody.count) 6 \(catalogBody.count + pageBody.count) "
        let inner = Data((header + catalogBody + pageBody + infoBody).utf8)
        let objStmStream = zlibCompress(inner)

        var offsets: [Int?] = Array(repeating: nil, count: 9)
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        func put(_ number: Int, _ body: String, stream: Data? = nil) {
            offsets[number] = out.count
            out += Data("\(number) 0 obj\n".utf8)
            if let stream {
                out += Data("\(body)\nstream\n".utf8)
                out += stream
                out += Data("\nendstream\n".utf8)
            } else {
                out += Data("\(body)\n".utf8)
            }
            out += Data("endobj\n".utf8)
        }
        put(2, pagesBody)
        put(5, "<< /Length \(content.count) >>", stream: content)
        put(7, "<< /Type /ObjStm /N 3 /First \(header.count) /Filter /FlateDecode /Length \(objStmStream.count) >>",
            stream: objStmStream)

        // Xref stream: 8 entries (objects 0–7), 7 bytes each.
        var xref = Data()
        func entry(_ type: Int, _ field2: Int, _ field3: Int) {
            xref.append(UInt8(type))
            xref.append(contentsOf: withUnsafeBytes(of: UInt32(field2).bigEndian) { Array($0) })
            xref.append(contentsOf: withUnsafeBytes(of: UInt16(field3).bigEndian) { Array($0) })
        }
        entry(0, 0, 65535)            // 0: free-list head
        entry(2, 7, 0)                 // 1: in object stream 7, index 0
        entry(1, offsets[2]!, 0)       // 2
        entry(2, 7, 1)                 // 3: index 1
        entry(0, 0, 65535)             // 4: unused
        entry(1, offsets[5]!, 0)       // 5
        entry(2, 7, 2)                 // 6: index 2
        entry(1, offsets[7]!, 0)       // 7
        let xrefStream = zlibCompress(xref)
        offsets[8] = out.count
        out += Data("8 0 obj\n<< /Type /XRef /W [1 4 2] /Index [0 8] /Size 8 /Root 1 0 R /Info 6 0 R /Filter /FlateDecode /Length \(xrefStream.count) >>\nstream\n".utf8)
        out += xrefStream
        out += Data("\nendstream\nendobj\n".utf8)
        out += Data("startxref\n\(offsets[8]!)\n%%EOF\n".utf8)
        try out.write(to: url)
    }

    /// Compresses to a PDF-compatible zlib stream (RFC 1950): Apple's
    /// COMPRESSION_ZLIB emits raw DEFLATE (RFC 1951), so the 2-byte header
    /// and the Adler-32 checksum are added here.
    static func zlibCompress(_ data: Data) -> Data {
        let deflated = rawDeflate(data)
        var out = Data([0x78, 0x9C])
        out += deflated
        out += withUnsafeBytes(of: adler32(data).bigEndian) { Data($0) }
        return out
    }

    private static func rawDeflate(_ data: Data) -> Data {
        var capacity = max(64, data.count + data.count / 2)
        while capacity < (1 << 24) {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = dst.withUnsafeMutableBytes { ptr in
                data.withUnsafeBytes { src in
                    compression_encode_buffer(
                        ptr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written < capacity { return Data(dst[0..<written]) }
            capacity *= 2
        }
        return Data()
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
