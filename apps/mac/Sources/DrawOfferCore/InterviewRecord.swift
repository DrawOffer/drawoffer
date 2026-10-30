import Foundation

/// 一场面试的记录（`questions_markdown`），对应 Web `progress/interviewRecord.ts`。
/// 一段一轮：`面试官：` 问题、`我：` 回答、`面试官（追问）：` 追问、`面试官（回答）：` 反问时面试官的回答。
/// 旧记录（编号列表、自由文本、“说话人 1/2”）也能读。
public struct RecordQuestion: Sendable, Equatable {
    public struct FollowUp: Sendable, Equatable { public var question: String; public var answer: String }
    public var question: String
    public var answer: String
    public var reply: String?
    public var followUps: [FollowUp]
    public init(question: String, answer: String = "", reply: String? = nil, followUps: [FollowUp] = []) {
        self.question = question; self.answer = answer; self.reply = reply; self.followUps = followUps
    }
}

public enum InterviewRecord {
    static let interviewer = "面试官", followUp = "面试官（追问）", reply = "面试官（回答）", candidate = "我"

    /// `(label, text)` when the paragraph starts with "label：" (label ≤ 12 non-space chars, or 说话人 N).
    static func turn(_ paragraph: String) -> (String, String)? {
        let trimmed = paragraph.drop { $0.isWhitespace }
        guard let colon = trimmed.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let label = String(trimmed[..<colon])
        let speaker = label.hasPrefix("说话人") && label.dropFirst(3).trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) && label.count > 3
        guard speaker || (!label.isEmpty && label.count <= 12 && !label.contains(where: \.isWhitespace)) else { return nil }
        return (speaker ? label : label, String(trimmed[trimmed.index(after: colon)...]))
    }

    public static func parse(_ markdown: String?) -> [RecordQuestion] {
        let source = (markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        let paragraphs = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").reduce(into: [[String]]([[]])) { groups, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { if !(groups.last?.isEmpty ?? true) { groups.append([]) } } else { groups[groups.count - 1].append(line) }
            }
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let labelled = paragraphs.filter { turn($0) != nil }.count
        if Double(labelled) >= max(1, Double(paragraphs.count) / 2) { return parseTurns(paragraphs) }
        return parseList(source)
    }

    static func parseTurns(_ paragraphs: [String]) -> [RecordQuestion] {
        var questions: [RecordQuestion] = []
        var speaker: String?
        var lastWasFollowUp = false
        func append(_ current: String, _ text: String) -> String { current.isEmpty ? text : current + "\n" + text }
        for paragraph in paragraphs {
            let match = turn(paragraph)
            let label = match?.0
            let text = (match?.1 ?? paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // 没写名字时，先开口的当作面试官
            if let label, label.hasPrefix("说话人"), speaker == nil { speaker = label }
            let asks = label == interviewer || label == followUp || (label != nil && label == speaker)
            if label == reply, !questions.isEmpty {
                questions[questions.count - 1].reply = append(questions[questions.count - 1].reply ?? "", text); lastWasFollowUp = false
            } else if asks, label == followUp, !questions.isEmpty {
                questions[questions.count - 1].followUps.append(.init(question: text, answer: "")); lastWasFollowUp = true
            } else if asks || questions.isEmpty {
                questions.append(RecordQuestion(question: text)); lastWasFollowUp = false
            } else if lastWasFollowUp, !questions[questions.count - 1].followUps.isEmpty {
                let last = questions[questions.count - 1].followUps.count - 1
                questions[questions.count - 1].followUps[last].answer = append(questions[questions.count - 1].followUps[last].answer, text)
            } else {
                questions[questions.count - 1].answer = append(questions[questions.count - 1].answer, text)
            }
        }
        return questions
    }

    static func parseList(_ source: String) -> [RecordQuestion] {
        var questions: [RecordQuestion] = []
        let numbered = try! NSRegularExpression(pattern: #"^\s*(?:\d+[.)、]|[-*])\s+(.*)$"#)
        for line in source.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = numbered.firstMatch(in: line, range: range), let body = Range(match.range(at: 1), in: line) {
                questions.append(RecordQuestion(question: line[body].trimmingCharacters(in: .whitespaces))); continue
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if questions.isEmpty { questions.append(RecordQuestion(question: text)) }
            else { questions[questions.count - 1].answer = questions[questions.count - 1].answer.isEmpty ? text : questions[questions.count - 1].answer + "\n" + text }
        }
        return questions
    }

    static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    public static func serialize(_ questions: [RecordQuestion]) -> String {
        var blocks: [String] = []
        for item in questions {
            let question = oneLine(item.question)
            guard !question.isEmpty else { continue }
            blocks.append("\(interviewer)：\(question)")
            if !oneLine(item.answer).isEmpty { blocks.append("\(candidate)：\(oneLine(item.answer))") }
            if !oneLine(item.reply ?? "").isEmpty { blocks.append("\(reply)：\(oneLine(item.reply ?? ""))") }
            for follow in item.followUps where !oneLine(follow.question).isEmpty {
                blocks.append("\(followUp)：\(oneLine(follow.question))")
                if !oneLine(follow.answer).isEmpty { blocks.append("\(candidate)：\(oneLine(follow.answer))") }
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// `record:structure` 的返回（`InterviewRecordDraft`）转成题目。
    public static func draft(_ value: JSONValue) -> [RecordQuestion] {
        (value["questions"]?.items ?? []).map { item in
            RecordQuestion(question: item.text("question"), answer: item.text("answer"), reply: item.text("reply").isEmpty ? nil : item.text("reply"),
                           followUps: (item["follow_ups"]?.items ?? []).map { .init(question: $0.text("question"), answer: $0.text("answer")) })
        }
    }

    public static func answered(_ questions: [RecordQuestion]) -> Int { questions.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
}
