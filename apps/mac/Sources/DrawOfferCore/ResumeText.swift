import CryptoKit
import Foundation
import PDFKit

/// 简历导入前在本机提取 PDF 文字（`POST /api/resumes/import` 接受 `.txt`）：服务端跳过文件转换与 OCR，按每行一段走同一结构化流程。
///
/// 只对“单栏、有文字层”的 PDF 这样做；扫描件（没有文字层）、多栏排版、乱码字体、加密或超过 10 页的仍上传原文件，
/// 由服务端重建阅读顺序或 OCR。DOCX 常见文本框与表格版式，系统读取可能漏字，也照常上传原文件；Markdown 本来就是文字。
public enum ResumeText {
    public static func extract(pdf data: Data) -> String? {
        guard let document = PDFDocument(data: data), !document.isEncrypted, (1...10).contains(document.pageCount) else { return nil }
        var pages: [String] = []
        var lines: [(minX: CGFloat, width: CGFloat)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { return nil }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0 else { return nil }
            for line in page.selection(for: box)?.selectionsByLine() ?? [] {
                guard !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let bounds = line.bounds(for: page)
                lines.append(((bounds.minX - box.minX) / box.width, bounds.width / box.width))
            }
            pages.append(text)
        }
        guard columnsLookSingle(lines) else { return nil }
        let text = pages.joined(separator: "\n").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return readable(text) ? text : nil
    }

    /// 单栏判断：每页去掉空行后至少 5 行；起点在页宽 45% 以右的行（右栏）不超过 15%。
    /// 版心两侧对齐的日期、地点和正文同一基线，会合成一行，不算右栏。
    static func columnsLookSingle(_ lines: [(minX: CGFloat, width: CGFloat)]) -> Bool {
        guard lines.count >= 5 else { return false }
        let right = lines.filter { $0.minX > 0.45 }.count
        return Double(right) / Double(lines.count) <= 0.15
    }

    /// 足够的正文（至少 200 个非空白字符），没有 NUL，替换符与私用区字符（字体缺 ToUnicode 时的乱码）不超过 1%。
    static func readable(_ text: String) -> Bool {
        guard !text.contains("\u{0}") else { return false }
        let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard visible.count >= 200 else { return false }
        let broken = visible.filter { $0 == "\u{FFFD}" || (0xE000...0xF8FF).contains($0.value) }.count
        return Double(broken) / Double(visible.count) <= 0.01
    }

    /// 文字版退回原文件时用的幂等键：由原键派生，重试同一次导入得到同一个键。
    static func fallbackKey(_ key: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("original:" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

extension ResumeImportUpload {
    /// PDF 能在本机可靠取出文字时的纯文本版本：文件名为“原名.txt”（简历名取文件名主干），幂等键不变。
    public func textVariant() -> ResumeImportUpload? {
        guard contentType == "application/pdf", let text = ResumeText.extract(pdf: content) else { return nil }
        let data = Data(text.utf8)
        guard data.count <= Self.maximumBytes else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        return ResumeImportUpload(fileName: (stem.isEmpty ? "简历" : stem) + ".txt", contentType: "text/plain", content: data,
                                  templateID: templateID, idempotencyKey: idempotencyKey)
    }

    func withIdempotencyKey(_ key: String) -> ResumeImportUpload {
        ResumeImportUpload(fileName: fileName, contentType: contentType, content: content, templateID: templateID, idempotencyKey: key)
    }
}
