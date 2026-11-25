import Foundation
import Network
import Observation

/// 网络是否可用（Web `PageUpdateNotice` 的「网络断开了」状态胶囊）：系统报告没有可用网络时为 offline。
@MainActor @Observable
final class NetworkStatus {
    private(set) var offline = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.offline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "drawoffer.network-status"))
    }
}
