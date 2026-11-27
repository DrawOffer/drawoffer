import Foundation

/// 面试中（Web `mock-interview/v2/sessionModel.ts`）：当前题、所在的那一轮、计时与是否已作答。
public enum MockSession {
    public static func current(_ detail: JSONValue) -> JSONValue? {
        let id = detail.display("current_question_id")
        guard !id.isEmpty else { return nil }
        return (detail["questions"]?.items ?? []).first { $0.display("id") == id }
    }

    public static func lastAsked(_ detail: JSONValue) -> JSONValue? {
        (detail["questions"]?.items ?? []).max { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
    }

    public static func roundOf(_ detail: JSONValue, _ question: JSONValue?) -> MockMap.Round? {
        guard let question else { return nil }
        let root = question.display("parent_id").nonEmptyValue ?? question.display("id")
        return MockMap.rounds(detail).first { $0.main.display("id") == root }
    }

    public static func mmss(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    public static func hasAnswered(_ detail: JSONValue) -> Bool {
        (detail["questions"]?.items ?? []).contains { $0.text("answer_status") == "answered" && !MockMap.isIntro(detail, $0) }
    }
}
