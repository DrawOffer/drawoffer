import AppKit
import DrawOfferCore
import SwiftUI

/// 首页数据：简历、资料、面试场次、记忆与画像，供首页问候与对话使用。
@MainActor @Observable
final class HomeImproveModel {
    enum State { case loading, failed, ready(HomeInput) }
    private(set) var state: State = .loading
    private var owner = ""
    private var disclosed = ""

    func load(api: any APIClient, account: String) async {
        owner = account
        guard !account.isEmpty else { return }
        state = .loading
        let now = Date()
        // 时间窗取整到小时：同一小时内反复进首页，排期列表直接用缓存
        let window = ReadCache.floor(now, minutes: 60)
        let iso = ISO8601DateFormatter()
        do {
            async let resumes = api.listResumes()
            async let datasets = try? api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil)
            async let sessions = try? api.careerRequest(path: "/api/interview-sessions", method: "GET",
                query: ["start_at": iso.string(from: window.addingTimeInterval(-60 * 86_400)), "end_at": iso.string(from: window.addingTimeInterval(30 * 86_400))], body: nil)
            async let home = try? api.careerRequest(path: "/api/memory/home", method: "GET", query: [:], body: nil)
            async let profile = try? api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            let resumeList = try await resumes
            let (datasetJSON, sessionJSON, homeJSON, profileJSON) = await (datasets, sessions, home, profile)
            guard owner == account else { return }
            state = .ready(HomeInput(
                now: now, home: homeJSON.map(MemoryHome.init(json:)),
                resumes: resumeList.map { HomeResume(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) },
                datasets: (datasetJSON?["datasets"]?.items ?? []).map(HomeDataset.init(json:)),
                sessions: (sessionJSON?["items"]?.items ?? []).compactMap(HomeSession.init(json:)),
                directions: (profileJSON?["job_directions"]?.items ?? []).compactMap(\.stringValue),
                targetRole: profileJSON?.text("target_role").nonEmptyOr("")))
        } catch {
            guard owner == account else { return }
            state = .failed
        }
    }

    /// 这一屏列出的问题登记为已告知（同一屏只报一次，失败下次再报）。
    func disclose(api: any APIClient, keys: [String]) {
        let signature = keys.joined(separator: "|")
        guard !keys.isEmpty, signature != disclosed else { return }
        disclosed = signature
        Task {
            do { _ = try await api.careerRequest(path: "/api/memory/home/disclosures", method: "POST", query: [:], body: .object(["issues": .array(keys.map(JSONValue.string))])) }
            catch { if disclosed == signature { disclosed = "" } }
        }
    }
}
