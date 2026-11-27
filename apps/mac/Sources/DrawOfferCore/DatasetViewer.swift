import Foundation

/// 资料预览独立页（Web `features/datasets/viewer`）里不依赖界面的部分：按类型分流、页头元信息、
/// 缩放档位、播放条波形、文字稿分段、Markdown 目录、出错文案。
public enum DatasetViewer {
    public enum Kind: Equatable, Sendable { case pdf, docx, markdown, text, image, audio, video, other }

    /// 解析 / 转写进行中时页面每 3 秒重读一次。
    public static let pollSeconds = 3
    /// MD / TXT 停止输入约 1 秒自动保存。
    public static let saveDelay: Duration = .seconds(1)

    public static func kind(_ record: DatasetRecord) -> Kind {
        let format = record.raw.text("file_format").lowercased()
        switch record.raw.text("asset_kind") {
        case "audio": return .audio
        case "video": return .video
        case "image": return .image
        default: break
        }
        return ["pdf": .pdf, "docx": .docx, "md": .markdown, "txt": .text][format] ?? .other
    }

    /// 解析 / 转写排队或进行中。
    public static func active(_ record: DatasetRecord) -> Bool { ["queued", "processing"].contains(record.raw.text("parse_status")) }
    /// 页面需要轮询：处理中或还在上传。
    public static func pending(_ record: DatasetRecord) -> Bool { active(record) || record.raw.text("upload_status") == "uploading" }
    public static func sourceReady(_ record: DatasetRecord) -> Bool { record.raw.text("upload_status") == "succeeded" }
    public static func textMode(_ record: DatasetRecord) -> Bool { [.markdown, .text].contains(kind(record)) }
    /// MD / TXT 上传完成且不在解析中才能改。
    public static func editable(_ record: DatasetRecord) -> Bool { textMode(record) && sourceReady(record) && !active(record) }
    /// 经历复习稿：来自简历某一段的 MD / TXT，页头主按钮换成「练这段经历」。
    public static func experienceSource(_ record: DatasetRecord) -> (resume: String, entry: String)? {
        let resume = record.raw.text("source_resume_id"), entry = record.raw.text("source_entry_id")
        return !resume.isEmpty && !entry.isEmpty && textMode(record) ? (resume, entry) : nil
    }

    /// 格式角标（`datasetFormatTone` 的文字）：最多四个字母。
    public static func formatLabel(_ record: DatasetRecord) -> String { String((record.format.isEmpty ? "FILE" : record.format).prefix(4)) }

    /// 「10-12」：北京时间的月-日。
    public static func uploadDay(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return value }
        return Beijing.formatter("MM-dd", locale: Locale(identifier: "en_US_POSIX")).string(from: date)
    }

    /// 「2026-10-15」：文字稿的转写日期。
    public static func fullDay(_ value: String) -> String? {
        guard let date = CareerApplication.date(value) else { return nil }
        return Beijing.formatter("yyyy-MM-dd", locale: Locale(identifier: "en_US_POSIX")).string(from: date)
    }

    public static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds), hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }

    // MARK: 页头元信息

    public enum SaveStatus: Equatable, Sendable { case idle, dirty, saving, saved, error, conflict }

    /// 页头右侧灰字，用「 · 」连起来（Web `meta`）：大小 → 页数 → 尺寸 → 时长 → 上传 / 更新日 → 已关联 → 正在解析。
    /// 保存状态另算（可以点），见 `saveLabel`。
    public static func meta(_ record: DatasetRecord, pages: Int? = nil, imageSize: CGSize? = nil, duration: Double? = nil) -> [String] {
        let source = experienceSource(record) != nil
        let kind = kind(record)
        var items: [String] = source ? [] : [JobProjects.size(record.raw["file_size"]?.numberValue ?? 0)]
        if let pages, pages > 0 { items.append("\(pages) 页") }
        if let imageSize, imageSize.width > 0 { items.append("\(Int(imageSize.width))×\(Int(imageSize.height))") }
        if kind == .audio || kind == .video, let duration, duration > 0 { items.append(formatClock(duration)) }
        items.append(source ? "\(uploadDay(record.raw.text("content_updated_at").nonEmptyValue ?? record.raw.text("created_at"))) 更新"
                            : "\(uploadDay(record.raw.text("created_at"))) 上传")
        if let label = record.raw.text("interview_label").nonEmptyValue { items.append("已关联 \(label)") }
        if ![.audio, .video, .image].contains(kind), active(record) { items.append("正在解析…") }
        return items
    }

    /// 保存状态；`error` / `conflict` 可点（重试 / 重新载入）。
    public static func saveLabel(_ status: SaveStatus) -> String? {
        switch status {
        case .dirty, .saving: return "正在保存…"
        case .saved: return "已保存"
        case .error: return "保存失败，点此重试"
        case .conflict: return "已在别处修改，点此重新载入"
        case .idle: return nil
        }
    }

    /// `If-Match: "dataset-<id>-<revision>"`。
    public static func ifMatch(id: String, revision: String) -> String { "\"dataset-\(id)-\(revision)\"" }

    /// `PUT /api/datasets/{id}/text` 的请求体：调用方把版本放在 `__revision`，这里拆成 `If-Match` 和只含 `text` 的正文。
    public static func textBody(text: String, revision: String) -> JSONValue { .object(["text": .string(text), "__revision": .string(revision)]) }
    public static func textSave(path: String, body: JSONValue?) -> (String, JSONValue)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[3] == "text", DatasetRequest.id(parts[2]),
              let text = body?["text"]?.stringValue, let revision = body?.text("__revision"),
              !revision.isEmpty, revision.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return (ifMatch(id: parts[2], revision: revision), .object(["text": .string(text)]))
    }

    // MARK: 缩放

    public static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    public static func zoomIn(_ scale: Double) -> Double { zoomSteps.first { $0 > scale + 0.001 } ?? zoomSteps[zoomSteps.count - 1] }
    public static func zoomOut(_ scale: Double) -> Double { zoomSteps.last { $0 < scale - 0.001 } ?? zoomSteps[0] }
    public static func clampZoom(_ scale: Double) -> Double { min(zoomSteps[zoomSteps.count - 1], max(zoomSteps[0], scale)) }
    /// 适合宽度：页面两侧各留 48。
    public static func fitWidth(available: Double, widest: Double) -> Double { widest > 0 ? clampZoom((available - 96) / widest) : 1 }
    /// 图片适应窗口：四周各留 96，只缩不放。
    public static func fitImage(stage: CGSize, image: CGSize, rotated: Bool) -> Double {
        let width = rotated ? image.height : image.width, height = rotated ? image.width : image.height
        guard width > 0, height > 0, stage.width > 0 else { return 1 }
        return max(0.01, min(1, (stage.width - 192) / width, (stage.height - 192) / height))
    }

    // MARK: 音频

    public static let speeds: [Double] = [1, 1.25, 1.5, 2, 0.75]
    public static func nextSpeed(_ speed: Double) -> Double { speeds[((speeds.firstIndex(of: speed) ?? -1) + 1) % speeds.count] }
    /// 「1.0×」「1.25×」「1.5×」。
    public static func speedLabel(_ speed: Double) -> String {
        var text = String(format: speed.truncatingRemainder(dividingBy: 1) == 0 ? "%.1f" : "%.2f", speed)
        if text.hasSuffix("0") && text.count > 3 { text.removeLast() }
        return text + "×"
    }

    /// 播放条波形只表示进度：按资料编号生成固定起伏（同 Web `waveform` 的做法；JS 大数相乘会丢精度，两端条形不必逐根相同），高度 6–26。
    public static func waveform(seed: String, count: Int) -> [Int] {
        var value: UInt32 = 0
        for scalar in seed.utf16 { value = value &* 31 &+ UInt32(scalar) }
        return (0..<max(0, count)).map { index in
            value = value &* 1103515245 &+ 12345
            let wave = abs(sin(Double(index) / 3.1)) * 0.6 + Double((value >> 16) % 100) / 250
            return max(6, Int((wave * 26).rounded()))
        }
    }

    public struct Turn: Equatable, Sendable {
        public let speaker: String?
        public let text: String
    }

    /// 文字稿按空行分段；段首「说话人：」拆出说话人（最多 16 个字）。
    public static func transcript(_ markdown: String) -> [Turn] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{2,}"#, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}").compactMap { block in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if let colon = trimmed.firstIndex(where: { $0 == "：" || $0 == ":" }) {
                    let speaker = trimmed[..<colon]
                    if (1...16).contains(speaker.count), !speaker.contains("\n") {
                        return Turn(speaker: speaker.trimmingCharacters(in: .whitespaces), text: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                return Turn(speaker: nil, text: trimmed)
            }
    }

    /// 还没有文字稿时的说明（Web `TranscriptionPrompt`）。
    public static func transcriptionMessage(_ record: DatasetRecord) -> String {
        switch record.raw.text("parse_status") {
        case "queued": return "等待转写"
        case "processing": return "正在转写…"
        case "failed":
            return ["service_unavailable": "语音识别服务未配置或暂不可用，请检查模型设置后重试。",
                    "content_invalid": "未识别到有效语音，请检查音频后重试。",
                    "size_exceeded": "音频超过语音服务大小限制；AIHubMix 单次转写最多支持 25 MB。"][record.raw.text("failure_reason")] ?? "转写失败，请稍后重试。"
        default: return "这份音频还没有文字稿，可开始转写。"
        }
    }

    // MARK: Markdown 目录

    public struct Heading: Equatable, Sendable {
        public let level: Int
        public let text: String
        /// 第几行（从 0 起）。
        public let line: Int
    }

    /// ATX 标题（`#`–`######` 后跟空格），跳过代码块里的行。
    public static func headings(_ markdown: String) -> [Heading] {
        var result: [Heading] = [], fenced = false
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level), line.dropFirst(level).first == " " else { continue }
            let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            guard !text.isEmpty else { continue }
            result.append(Heading(level: level, text: text, line: index))
        }
        return result
    }

    /// 阅读态按行排版（同 Web 编辑器的实时预览：一行源码一行，空行 12 高）；代码块、表格、分隔线整块显示。
    public enum Line: Equatable, Sendable {
        case blank
        case heading(level: Int, text: String, line: Int)
        case text(String)
        /// `marker`：「•」或「1.」；`checked` 为任务列表的勾选状态。
        case item(marker: String, text: String, checked: Bool?, indent: Int)
        case quote(String)
        case code(language: String, text: String)
        case table([[String]])
        case rule
    }

    public static func lines(_ markdown: String) -> [Line] {
        let source = markdown.components(separatedBy: "\n")
        var result: [Line] = [], index = 0
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        func separator(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
        }
        while index < source.count {
            let raw = source[index], line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3)), language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []; index += 1
                while index < source.count, !source[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(source[index]); index += 1 }
                result.append(.code(language: language, text: body.joined(separator: "\n"))); index += 1; continue
            }
            if line.contains("|"), index + 1 < source.count, separator(source[index + 1]) {
                var rows = [cells(line)]; index += 2
                while index < source.count, source[index].contains("|"), !source[index].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(source[index])); index += 1 }
                result.append(.table(rows)); continue
            }
            defer { index += 1 }
            if line.isEmpty { result.append(.blank); continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                result.append(.heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression), line: index)); continue
            }
            if line.count >= 3, ["-", "*", "_"].contains(where: { mark in line.replacingOccurrences(of: " ", with: "").allSatisfy { String($0) == mark } }) { result.append(.rule); continue }
            if line.hasPrefix(">") { result.append(.quote(String(line.drop(while: { $0 == ">" || $0 == " " })))); continue }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
                var text = String(line.dropFirst(2)), checked: Bool? = nil
                if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) } else if text.lowercased().hasPrefix("[x] ") { checked = true; text.removeFirst(4) }
                result.append(.item(marker: "•", text: text, checked: checked, indent: indent)); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), line[..<dot].count <= 3, !line[..<dot].isEmpty,
               line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " " {
                result.append(.item(marker: String(line[...dot]), text: line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces), checked: nil, indent: indent)); continue
            }
            result.append(.text(line))
        }
        return result
    }

    /// 目录只列二、三级标题；没有二级标题时退回一到三级。
    public static func outline(_ headings: [Heading]) -> [Heading] {
        headings.contains { $0.level == 2 } ? headings.filter { $0.level == 2 || $0.level == 3 } : headings.filter { $0.level <= 3 }
    }

    // MARK: 出错文案

    /// Web `datasetActionErrorMessage`。
    public static func actionError(_ error: Error, fallback: String) -> String {
        if case APIError.unauthorized = error { return "登录状态已失效，请重新登录。" }
        guard case APIError.server(let status, let code) = error else { return fallback }
        switch code {
        case "INVALID_DATASET_NAME": return "资料名称不能为空，不能包含路径符号或控制字符。"
        case "DATASET_NOT_FOUND": return "这份资料不存在或你无权操作。"
        case "FOLDER_NOT_FOUND": return "项目不存在或已被删除，请重新选择。"
        case "FOLDER_DELETE_CONFIRMATION_REQUIRED": return "项目内包含资料，请确认后再删除。"
        case "DATASET_IN_PROGRESS", "DATASET_BUSY": return "资料正在解析，处理完成后再删除。"
        case "DATASET_NOT_RETRYABLE": return "只有解析失败的资料可以重新解析。"
        case "DATASET_SOURCE_UNAVAILABLE": return "原始文件已不可用，请重新上传资料。"
        case "DATASET_QUEUE_UNAVAILABLE": return "解析服务暂不可用，资料已保留为解析失败。"
        case "ASSET_DELETE_FAILED": return "资料清理失败，请稍后重试。"
        default:
            if status == 401 { return "登录状态已失效，请重新登录。" }
            return status >= 500 ? "服务暂时不可用，请稍后重试。" : fallback
        }
    }

    /// 打开页面时读不到这份资料：404 / DATASET_NOT_FOUND 说明不存在，不给「重新加载」。
    public static func missing(_ error: Error) -> Bool {
        if case APIError.server(let status, let code) = error { return status == 404 || code == "DATASET_NOT_FOUND" }
        return false
    }

    /// 读出来的原文：去掉 BOM，换行统一成 `\n`。
    public static func normalizedText(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
