import AppKit
import DrawOfferCore

/// 等后台任务（复盘、转写、评估、导入、资料解析）落定时的统一节奏：
/// - 实时事件连着时（`EventHub.live`）等对应 topic 的事件，最长 60 秒兜底查一次（事件不重发，少数批量更新也不发事件）；
/// - 没连上时退回轮询：间隔从 `first` 秒起每次乘 1.5，封顶 `cap` 秒；
/// - App 不在前台时不查，回到前台立刻补查一次；
/// - 每次只查任务状态（单条、不进缓存的接口），状态变了才作废读缓存、整页刷新。
@MainActor
enum Polling {
    static let fallback = 60.0

    static func delay(_ attempt: Int, first: Double, cap: Double) -> Double {
        min(cap, first * pow(1.5, Double(max(0, attempt))))
    }

    /// 等到下一次该查的时候：收到 `topic`（`ref` 不为空时只认这一条或不带 ref 的）事件、事件流断开后到了轮询间隔、或兜底时间到。任务已取消时返回 false。
    static func wait(_ attempt: Int, first: Double, cap: Double, topic: String? = nil, ref: String? = nil) async -> Bool {
        let hub = EventHub.shared, start = Date()
        let mark = topic.map { hub.mark($0, ref) }
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if let topic, let mark, hub.mark(topic, ref) != mark { break }
            if elapsed >= (topic != nil && hub.live ? fallback : delay(attempt, first: first, cap: cap)) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        while !Task.isCancelled, !NSApp.isActive { try? await Task.sleep(for: .seconds(1)) }
        return !Task.isCancelled
    }
}

/// 登录期间保持一条 `GET /api/events`：
/// - `ready`（连上、服务端重连 MQ）与业务 `change` 都作废读缓存，并唤醒等这个 topic 的页面；`notification` 只刷新消息中心；
/// - 流正常结束（令牌到期、服务端重启）1 秒后重连；404（服务端没启用）不再连；其他失败按 3 秒起翻倍退避，最长 15 分钟；
/// - 断开期间 `live` 为 false，各页面退回轮询。
@MainActor
final class EventHub {
    static let shared = EventHub()
    private(set) var live = false
    private var marks: [String: Int] = [:]

    /// 某个 topic（可选限定 ref）的事件计数；`ready` 计入所有 topic。
    func mark(_ topic: String, _ ref: String?) -> Int {
        let ready = marks["ready"] ?? 0
        guard let ref else { return ready &+ (marks[topic] ?? 0) }
        return ready &+ (marks[topic + ":" + ref] ?? 0) &+ (marks[topic + ":"] ?? 0)
    }

    func run(api: any APIClient, notified: @escaping @MainActor () -> Void) async {
        var failures = 0
        defer { live = false }
        while !Task.isCancelled {
            do {
                try await api.streamEvents { event in await EventHub.shared.receive(event, api: api, notified: notified) }
                live = false; failures = 0
                try? await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch APIError.server(404, _) {
                return
            } catch APIError.unauthorized {
                return
            } catch {
                live = false; failures += 1
                try? await Task.sleep(for: .seconds(min(900, 3 * pow(2, Double(min(failures, 9))))))
            }
        }
    }

    private func receive(_ event: UserEvent, api: any APIClient, notified: @MainActor () -> Void) async {
        switch event {
        case .ready:
            live = true
            marks["ready", default: 0] &+= 1
            await api.purgeCache()
            notified()
        case .change(let topic, let ref):
            marks[topic, default: 0] &+= 1
            marks[topic + ":" + (ref ?? ""), default: 0] &+= 1
            if topic == "notification" { notified() } else { await api.purgeCache() }
        }
    }
}
