import Foundation

/// 资料库「求职进程」项目（Web `datasets/jobProjects.ts`）：不单独存储，由投递 + 面试场次 + 关联到场次的资料 + Offer 材料聚合。
public enum JobProjects {
    public enum State: String, Sendable { case done, current, upcoming, offer }

    public struct Node: Sendable {
        public let key: String
        public let label: String
        public let state: State
        public let date: String?
        public let sessionID: String?
        public let datasets: [DatasetRecord]
    }

    public struct Project: Sendable, Identifiable {
        public let id: String
        public let application: JSONValue
        public let name: String
        public let monogram: String
        public let statusLabel: String
        public let archived: Bool
        public let nodes: [Node]
        public let datasetCount: Int
        public let recordCount: Int
        public let lastActivity: Double

        public var offer: Bool { ["received", "accepted"].contains(application.text("offer_status")) }
        /// 下一场：没归档时第一个 current 节点。
        public var next: Node? { archived ? nil : nodes.first { $0.state == .current } }
        /// 强调「下一场」，没有下一场时强调最后走到的阶段。
        public var focusKey: String? { (next ?? nodes.last { $0.state != .upcoming })?.key }
        /// 阶段链最多 5 个阶段：保留投递和最近 3 个，中间用省略号（nil）。
        public var chain: [Node?] { nodes.count <= 5 ? nodes : [nodes[0], nil] + nodes.suffix(3) }
        public var materialSummary: String {
            let parts = [datasetCount > 0 ? "\(datasetCount) 份资料" : "", recordCount > 0 ? "\(recordCount) 份记录" : ""].filter { !$0.isEmpty }
            return parts.isEmpty ? "还没有资料" : parts.joined(separator: " · ")
        }
    }

    public static func time(_ value: String?) -> Double { value.flatMap(CareerApplication.date)?.timeIntervalSince1970 ?? 0 }

    public static func name(_ application: JSONValue) -> String {
        let company = application.text("company_name_snapshot").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = application.text("job_title_snapshot").trimmingCharacters(in: .whitespacesAndNewlines)
        return !company.isEmpty && !title.isEmpty ? "\(company) · \(title)" : company.isEmpty ? (title.isEmpty ? "未命名岗位" : title) : company
    }

    public static func statusLabel(_ application: JSONValue, now: Date = Date()) -> String {
        if !application.text("archived_at").isEmpty { return "已归档" }
        if ["received", "accepted"].contains(application.text("offer_status")) { return "已获 Offer" }
        return CareerBoard.progressLabel(application, completed: false, now: now)
    }

    public static func build(_ applications: [JSONValue], _ sessions: [JSONValue], _ datasets: [DatasetRecord], now: Date = Date()) -> [Project] {
        var byApplication: [String: [JSONValue]] = [:]
        for session in sessions where session.text("status") != "cancelled" { byApplication[session.display("application_id"), default: []].append(session) }
        var bySession: [String: [DatasetRecord]] = [:], byID: [String: DatasetRecord] = [:]
        for dataset in datasets {
            byID[dataset.id] = dataset
            let session = dataset.raw.display("interview_session_id")
            if !session.isEmpty { bySession[session, default: []].append(dataset) }
        }
        let projects: [Project] = applications.filter { $0.text("phase") != "pending" }.map { application in
            let id = application.display("id")
            let ordered = (byApplication[id] ?? []).enumerated().sorted { (time($0.element.text("start_at")), $0.offset) < (time($1.element.text("start_at")), $1.offset) }.map(\.element)
            let firstUpcoming = ordered.firstIndex { $0.text("status") == "scheduled" }
            var nodes = [Node(key: "applied", label: "投递", state: .done, date: application.text("applied_at").nonEmptyValue ?? application.text("created_at"), sessionID: nil, datasets: [])]
            for (index, session) in ordered.enumerated() {
                let sid = session.display("id")
                let label = session.text("stage_label").trimmingCharacters(in: .whitespacesAndNewlines)
                nodes.append(Node(key: "session-\(sid)", label: label.isEmpty ? "面试" : label,
                                  state: session.text("status") == "completed" ? .done : index == firstUpcoming ? .current : .upcoming,
                                  date: session.text("start_at"), sessionID: sid,
                                  datasets: (bySession[sid] ?? []).enumerated().sorted { (time($0.element.raw.text("created_at")), $0.offset) < (time($1.element.raw.text("created_at")), $1.offset) }.map(\.element)))
            }
            let offerDatasets = (application["offer_materials"]?.items ?? []).compactMap { byID[$0.display("dataset_id")] }
            if ["received", "accepted"].contains(application.text("offer_status")) || !offerDatasets.isEmpty {
                nodes.append(Node(key: "offer", label: "Offer", state: .offer, date: application.text("offer_received_on").nonEmptyValue, sessionID: nil, datasets: offerDatasets))
            }
            let all = nodes.flatMap(\.datasets)
            let records = ordered.filter { !$0.text("questions_markdown").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0["written_questions"]?.items ?? []).isEmpty }.count
            let last = ([time(application.text("updated_at"))] + all.map { time($0.raw.text("created_at")) }).max() ?? 0
            let name = name(application)
            let company = application.text("company_name_snapshot").trimmingCharacters(in: .whitespacesAndNewlines)
            return Project(id: id, application: application, name: name, monogram: (company.isEmpty ? name : company).first.map(String.init) ?? "·",
                           statusLabel: statusLabel(application, now: now), archived: !application.text("archived_at").isEmpty,
                           nodes: nodes, datasetCount: all.count, recordCount: records, lastActivity: last)
        }
        return projects.enumerated().sorted { a, b in
            if a.element.archived != b.element.archived { return !a.element.archived }
            if a.element.lastActivity != b.element.lastActivity { return a.element.lastActivity > b.element.lastActivity }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 每份资料所在项目的显示名：求职进程项目优先。
    public static func labels(_ projects: [Project]) -> [String: String] {
        var labels: [String: String] = [:]
        for project in projects { for node in project.nodes { for dataset in node.datasets { labels[dataset.id] = project.name } } }
        return labels
    }

    /// `formatDatasetFileSize`：B / KB / MB / GB，整数不带小数，否则保留一位。
    public static func size(_ bytes: Double) -> String {
        func unit(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
        if bytes < 1024 { return "\(Int(bytes)) B" }
        if bytes < 1024 * 1024 { return unit(bytes / 1024) + " KB" }
        if bytes < 1024 * 1024 * 1024 { return unit(bytes / 1024 / 1024) + " MB" }
        return unit(bytes / 1024 / 1024 / 1024) + " GB"
    }
}
