import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private func application(_ extra: String = "", id: String = "a1", updated: String = "2026-09-12T02:00:00Z") -> JSONValue {
    json(#"{"id":""# + id + #"","company_name_snapshot":"虚构甲公司","job_title_snapshot":"后端开发","phase":"applied","offer_status":"received","offer_received_on":null,"applied_at":"2026-09-12T02:00:00Z","created_at":"2026-09-10T02:00:00Z","updated_at":""# + updated + #"""# + extra + "}")
}
private func session(_ id: String, label: String = "一面", status: String = "completed", start: String = "2026-09-26T02:00:00Z") -> JSONValue {
    json(#"{"id":""# + id + #"","application_id":"a1","stage_label":""# + label + #"","status":""# + status + #"","start_at":""# + start + #""}"#)
}
private func dataset(_ id: String, _ extra: String = "") -> DatasetRecord {
    DatasetRecord(json(#"{"id":""# + id + #"","folder_id":null,"file_name":""# + id + #".md","file_format":"md","file_size":10,"upload_status":"succeeded","parse_status":"succeeded","created_at":"2026-09-27T02:00:00Z""# + extra + "}"))
}

/// 与 Web `jobProjects.test.ts` 同样的三组用例。
@Test func jobProjectsMatchWeb() {
    let projects = JobProjects.build(
        [application(#","offer_materials":[{"dataset_id":"d3","file_name":"offer.pdf"}]"#)],
        [session("s2", label: "二面", status: "scheduled", start: "2026-10-08T02:00:00Z"), session("s1"), session("s0", label: "已取消", status: "cancelled")],
        [dataset("d1", #","interview_session_id":"s1","asset_kind":"audio""#), dataset("d2", #","interview_session_id":"s1""#), dataset("d3"), dataset("d4", #","interview_session_id":null"#)])
    let project = projects[0]
    #expect(project.name == "虚构甲公司 · 后端开发")
    #expect(project.monogram == "虚")
    #expect(project.statusLabel == "已获 Offer")
    #expect(project.nodes.map { "\($0.label)|\($0.state.rawValue)" } == ["投递|done", "一面|done", "二面|current", "Offer|offer"])
    #expect(project.nodes[1].datasets.map(\.id) == ["d1", "d2"])
    #expect(project.nodes[3].datasets.map(\.id) == ["d3"])
    #expect(project.datasetCount == 3)
    #expect(project.focusKey == "session-s2")
    #expect(project.materialSummary == "3 份资料")

    let sorted = JobProjects.build([
        json(#"{"id":"pending","phase":"pending","company_name_snapshot":"","job_title_snapshot":""}"#),
        application(#","archived_at":"2026-10-01T00:00:00Z","offer_materials":[]"#, id: "archived", updated: "2026-10-09T00:00:00Z"),
        application(id: "active", updated: "2026-09-01T00:00:00Z"),
    ], [], [])
    #expect(sorted.map(\.id) == ["active", "archived"])
    #expect(sorted[1].statusLabel == "已归档")

    let labelled = JobProjects.build([application()], [session("s1")], [dataset("d1", #","interview_session_id":"s1""#)])
    #expect(JobProjects.labels(labelled)["d1"] == "虚构甲公司 · 后端开发")
    let sizes: [Double] = [88, 1536, 524_288_000, 1_073_741_824]
    let labels: [String] = sizes.map { JobProjects.size($0) }
    #expect(labels == ["88 B", "1.5 KB", "500 MB", "1 GB"])
}
