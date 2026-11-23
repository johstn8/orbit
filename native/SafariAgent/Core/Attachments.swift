import Foundation
import PDFKit
import AppKit

/// A file the user attached to a chat message in the sidebar. It goes only to the
/// provider of that chat, as part of the user's own message.
struct Attachment {
    enum Kind { case image, pdf, text }
    let name: String
    let mime: String
    let kind: Kind
    let data: Data

    static let maxFiles = 5
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxTotalBytes = 30 * 1024 * 1024
    static let maxTextBytes = 1024 * 1024
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Validates what the extension sent (the panel limits this too; checked again here).
    static func parse(_ raw: Any?) throws -> [Attachment] {
        guard let list = raw as? [JSONObject], !list.isEmpty else { return [] }
        guard list.count <= maxFiles else { throw AgentError("too_many_files", "Attach at most \(maxFiles) files per message.") }
        var total = 0
        return try list.map { o in
            let name = String(((o["name"] as? String) ?? "file").replacingOccurrences(of: "\n", with: " ").prefix(120))
            guard let b64 = o["data"] as? String, let data = Data(base64Encoded: b64) else { throw AgentError("bad_file", "“\(name)” could not be read.") }
            guard data.count <= maxFileBytes else { throw AgentError("file_too_large", "“\(name)” is larger than 20 MB.") }
            total += data.count
            guard total <= maxTotalBytes else { throw AgentError("files_too_large", "The attached files are larger than 30 MB together.") }
            let mime = ((o["type"] as? String) ?? "").lowercased()
            if imageTypes.contains(mime) { return Attachment(name: name, mime: mime, kind: .image, data: data) }
            if mime == "application/pdf" || data.starts(with: Data("%PDF".utf8)) { return Attachment(name: name, mime: "application/pdf", kind: .pdf, data: data) }
            guard data.count <= maxTextBytes, String(data: data, encoding: .utf8) != nil else {
                throw AgentError("unsupported_file", "“\(name)” can't be attached. Images, PDFs and text files (up to 1 MB) are supported.")
            }
            return Attachment(name: name, mime: mime.isEmpty ? "text/plain" : mime, kind: .text, data: data)
        }
    }

    var textContent: String { "<attached_file name=\"\(name.replacingOccurrences(of: "\"", with: "'"))\">\n\(String(data: data, encoding: .utf8) ?? "")\n</attached_file>" }

    /// Content blocks for Claude Code's stream-json user message (Messages API format).
    static func claudeBlocks(_ files: [Attachment]) -> [JSONObject] {
        files.map { a in
            switch a.kind {
            case .image: return ["type": "image", "source": ["type": "base64", "media_type": a.mime, "data": a.data.base64EncodedString()]]
            case .pdf: return ["type": "document", "title": a.name, "source": ["type": "base64", "media_type": "application/pdf", "data": a.data.base64EncodedString()]]
            case .text: return ["type": "text", "text": a.textContent]
            }
        }
    }

    /// Content parts for the ChatGPT Responses API.
    static func chatGPTParts(_ files: [Attachment]) -> [JSONObject] {
        files.map { a in
            switch a.kind {
            case .image: return ["type": "input_image", "image_url": "data:\(a.mime);base64,\(a.data.base64EncodedString())"]
            case .pdf: return ["type": "input_file", "filename": a.name, "file_data": "data:application/pdf;base64,\(a.data.base64EncodedString())"]
            case .text: return ["type": "input_text", "text": a.textContent]
            }
        }
    }
}

/// PDFs the agent reads from Safari (the PDF viewer has no readable page text) and
/// combines into new files. The extension downloads a PDF with the profile's own
/// session and hands the bytes over; Orbit extracts text or renders pages with PDFKit.
/// Kept in memory only (a few recent documents).
final class PDFTools {
    static let shared = PDFTools()
    private let lock = NSLock()
    private var docs: [(url: String, data: Data)] = []
    private static let maxDocs = 6

    func store(url: String, data: Data) throws -> Int {
        guard let doc = PDFDocument(data: data) else { throw AgentError("not_pdf", "This file is not a readable PDF.") }
        if doc.isLocked { throw AgentError("pdf_locked", "This PDF is password-protected.") }
        lock.lock()
        docs.removeAll { $0.url == url }
        docs.append((url, data))
        if docs.count > Self.maxDocs { docs.removeFirst(docs.count - Self.maxDocs) }
        lock.unlock()
        return doc.pageCount
    }

    func has(_ url: String) -> Bool { lock.lock(); defer { lock.unlock() }; return docs.contains { $0.url == url } }

    private func document(_ url: String) throws -> PDFDocument {
        lock.lock(); let d = docs.last { $0.url == url }?.data; lock.unlock()
        guard let d, let doc = PDFDocument(data: d) else { throw AgentError("pdf_missing", "This PDF is no longer loaded. Read it again with read_pdf.") }
        return doc
    }

    /// "1-3,5" → zero-based indices within 0..<count (nil or empty = all pages).
    static func pages(_ spec: String?, count: Int) throws -> [Int] {
        let s = (spec ?? "").replacingOccurrences(of: " ", with: "")
        if s.isEmpty || s.lowercased() == "all" { return Array(0..<count) }
        var out: [Int] = []
        for part in s.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...2).contains(ends.count), let a = ends[0] else { throw AgentError("bad_pages", "Invalid page range “\(spec ?? "")”. Use e.g. 1-5,8.") }
            let b = ends.count == 2 ? (ends[1] ?? count) : a
            guard a >= 1, b >= a, a <= count else { throw AgentError("bad_pages", "Page range “\(part)” is outside 1–\(count).") }
            out.append(contentsOf: (a...min(b, count)).map { $0 - 1 })
        }
        return out
    }

    func text(url: String, pages spec: String?, offset: Int, maxChars: Int) throws -> (text: String, pageCount: Int) {
        let doc = try document(url)
        let idx = try Self.pages(spec, count: doc.pageCount)
        var all = ""
        for i in idx {
            let t = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            all += "--- Page \(i + 1) ---\n\(t.isEmpty ? "(no text on this page — it may be an image; use pages_as_images)" : t)\n\n"
        }
        let start = all.index(all.startIndex, offsetBy: min(max(0, offset), all.count))
        let slice = all[start...]
        let cut = slice.prefix(max(1000, maxChars))
        var text = String(cut)
        if cut.count < slice.count { text += "\n[truncated — continue with offset=\(min(max(0, offset), all.count) + cut.count)]" }
        return (text, doc.pageCount)
    }

    /// JPEG images of up to 6 pages (for slides that are pictures).
    func images(url: String, pages spec: String?) throws -> [(page: Int, base64: String)] {
        let doc = try document(url)
        let idx = Array(try Self.pages(spec, count: doc.pageCount).prefix(6))
        return idx.compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let box = page.bounds(for: .cropBox)
            let scale = min(2, 1280 / max(box.width, 1))
            let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
            return (i + 1, jpg.base64EncodedString())
        }
    }

    /// A new PDF from pages of loaded PDFs, saved as a new file (never overwrites).
    func compose(_ sources: [(url: String, pages: String?)], to folder: URL, filename: String) throws -> (URL, Int) {
        let out = PDFDocument()
        for s in sources {
            let doc = try document(s.url)
            for i in try Self.pages(s.pages, count: doc.pageCount) {
                if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
            }
        }
        guard out.pageCount > 0 else { throw AgentError("no_pages", "No pages were selected.") }
        let target = Self.uniqueURL(folder, Self.safeName(filename))
        guard out.write(to: target) else { throw AgentError("write_failed", "The PDF could not be saved.") }
        return (target, out.pageCount)
    }

    static func safeName(_ raw: String) -> String {
        var n = (raw as NSString).lastPathComponent
        n = n.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if n.hasPrefix(".") { n = "_" + n }
        if n.isEmpty { n = "Document" }
        if !n.lowercased().hasSuffix(".pdf") { n += ".pdf" }
        return String(n.prefix(120))
    }

    static func uniqueURL(_ folder: URL, _ name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).pdf")
            n += 1
        }
        return url
    }
}
