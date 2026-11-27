import CryptoKit
import Foundation

/// 读请求缓存规则：哪些 GET 可以复用、复用多久。
///
/// - 带内容哈希的公司 logo（`/logo?v=<64 位 sha256>`）内容永不变，内存与磁盘都长期保存。
/// - 价格、语音能力、插件版本、模板列表这类配置 10 分钟。
/// - 画像、偏好、投递与面试列表、资料夹 60 秒；任何写请求、窗口回到前台、轮询刷新前都会整体作废，
///   所以 60 秒只是在页面之间切换时少拉几次，不会挡住自己刚做的修改。
/// - 带处理中状态的接口（单条面试、模拟面试、资料、通知、积分、AI 对话）不缓存。
/// - 简历列表与单份简历另外留一份带 ETag 的副本：缓存作废后再读时带 `If-None-Match`，没变只回 304。
public enum ReadCache {
    public static let forever: TimeInterval = .infinity
    static let configPaths: Set<String> = ["/api/billing/feature-prices", "/api/mock-interviews/speech-capability",
                                           "/api/plugin-releases/current", "/api/resume-templates"]

    /// 服务端支持 ETag/304 的读：`/api/resumes`、`/api/resumes/{数字 id}` 与岗位广场筛选项 `/api/job-pool/filters`（约 700 KB，
    /// 按岗位池数据版本出 ETag），都不带查询参数。
    public static func validates(path: String, query: [String: String]) -> Bool {
        guard query.isEmpty else { return false }
        if path == "/api/resumes" || path == "/api/job-pool/filters" { return true }
        let prefix = "/api/resumes/"
        guard path.hasPrefix(prefix) else { return false }
        let id = path.dropFirst(prefix.count)
        return !id.isEmpty && id.count <= 20 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 某个写请求之后哪些缓存键要作废：
    /// - 配置类（价格、语音能力、插件版本、模板列表）和长期 logo 不受用户写操作影响，留着；
    /// - 模拟面试作答（answers、skip、reply:retry）只改那一场，本身不进缓存，什么都不用作废；
    /// - 资料库的写只作废资料夹，账号设置的写只作废账号类读；
    /// - 其余写请求可能牵动投递、面试、简历，作废全部用户数据。
    public static func affected(byWriteTo path: String, key: String) -> Bool {
        let readPath = key.hasPrefix("send:") ? String(key.dropFirst(5)) : String(key.split(separator: "?", maxSplits: 1).first ?? "")
        if configPaths.contains(readPath) || lifetime(path: readPath, query: logoQuery(key)) == forever { return false }
        if path.hasPrefix("/api/mock-interviews/"), ["answers", "skip", "reply:retry"].contains(String(path.split(separator: "/").last ?? "")) { return false }
        if path.hasPrefix("/api/datasets") { return readPath.hasPrefix("/api/datasets") }
        // 回复评价与切换提问版本只动对话本身，对话的读不进缓存
        if path.hasPrefix("/api/agent/sessions/"), path.hasSuffix("/rating") || path.hasSuffix(":switch") { return false }
        // 提交反馈不改任何用户数据
        if path == "/api/feedback" { return false }
        if path.hasPrefix("/api/account/") { return readPath.hasPrefix("/api/account/") }
        return true
    }

    private static func logoQuery(_ key: String) -> [String: String] {
        guard let query = key.split(separator: "?", maxSplits: 1).dropFirst().first, query.hasPrefix("v=") else { return [:] }
        return ["v": String(query.dropFirst(2))]
    }

    public static func lifetime(path: String, query: [String: String]) -> TimeInterval? {
        if path.hasPrefix("/api/job-descriptions/"), path.hasSuffix("/logo"), query.count == 1, let revision = query["v"], revision.count == 64 {
            return forever
        }
        if configPaths.contains(path) { return 600 }
        switch path {
        case "/api/account/user-profile", "/api/account/preferences", "/api/account/career-profile",
             "/api/job-applications", "/api/interview-sessions", "/api/interview-overview", "/api/datasets/folders", "/api/resumes":
            return 60
        default:
            return ["/api/job-pool", "/api/job-pool/count", "/api/job-pool/by-company", "/api/job-pool/filters"].contains(path) || path.hasPrefix("/api/job-pool/companies") ? 120 : nil
        }
    }

    /// 列表查询里的时间窗取整：几分钟内重复进入同一页面时查询参数相同，才能命中缓存。
    public static func floor(_ date: Date, minutes: Int) -> Date {
        let step = Double(max(1, minutes) * 60)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    /// 查询参数排序后拼进键里，同一请求不同参数分开缓存。
    public static func key(path: String, query: [String: String]) -> String {
        query.isEmpty ? path : path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// 长期缓存落盘的位置：`~/Library/Caches/<bundle>/responses/<sha256(键)>.json`。
    static func diskURL(_ key: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "DrawOffer", isDirectory: true)
            .appendingPathComponent("responses", isDirectory: true).appendingPathComponent(name + ".json")
    }

    static func readDisk(_ key: String) -> JSONValue? {
        guard let url = diskURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func writeDisk(_ key: String, _ value: JSONValue) {
        guard let url = diskURL(key), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 只在内存里的图片缓存：头像与简历图片路径带上传时间和随机串，同一路径内容不变；总量超过上限时先丢最早的。
struct ImageMemoryCache {
    private var items: [String: DesktopImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    let budget: Int

    init(budget: Int = 64 * 1024 * 1024) { self.budget = budget }

    func get(_ path: String) -> DesktopImage? { items[path] }

    mutating func put(_ path: String, _ image: DesktopImage) {
        guard items[path] == nil, image.data.count <= budget / 4 else { return }
        items[path] = image; order.append(path); bytes += image.data.count
        while bytes > budget, !order.isEmpty {
            let oldest = order.removeFirst()
            bytes -= items.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    mutating func removeAll() { items = [:]; order = []; bytes = 0 }
}

/// 头像与简历图片的磁盘缓存：`~/Library/Caches/<bundle>/images/<sha256(账号)>/<sha256(路径)>.png|jpg`。
/// 同一路径内容不变，所以重启后直接用；目录只有本人可读，退出或换账号时整个删掉，总量超过上限先删最久没用的。
struct ImageDiskCache: Sendable {
    let root: URL
    let budget: Int

    init(root: URL, budget: Int = 256 * 1024 * 1024) { self.root = root; self.budget = budget }

    static func standard() -> ImageDiskCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return ImageDiskCache(root: caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "DrawOffer", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(account: String, path: String, type: String) -> URL {
        root.appendingPathComponent(Self.digest(account), isDirectory: true)
            .appendingPathComponent(Self.digest(path) + (type == "image/png" ? ".png" : ".jpg"))
    }

    func get(account: String, path: String) -> DesktopImage? {
        for type in ["image/png", "image/jpeg"] {
            let url = file(account: account, path: path, type: type)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                return DesktopImage(data: data, contentType: type)
            }
        }
        return nil
    }

    func put(account: String, path: String, image: DesktopImage) {
        guard ["image/png", "image/jpeg"].contains(image.contentType), image.data.count <= budget / 4 else { return }
        let url = file(account: account, path: path, type: image.contentType)
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? image.data.write(to: url, options: .atomic)) != nil else { return }
        prune()
    }

    func removeAll() { try? FileManager.default.removeItem(at: root) }

    private func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, used: Date)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        for item in files.sorted(by: { $0.used < $1.used }) where total > budget {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }
}
