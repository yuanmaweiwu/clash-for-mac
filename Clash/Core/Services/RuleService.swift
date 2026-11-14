import Foundation
import Observation

/// 规则列表的数据源（`GET /rules`，`docs/02-UI-SPEC.md` §4.11）。
///
/// 边界：
/// - 只读快照，没有轮询：进页面拉一次，之后走缓存；「重试 / 刷新」才再发请求
/// - 内核停止 / 换配置时 `invalidate()` 作废缓存，下次进页面重新拉（不拿旧配置糊弄）
/// - 拉取失败保留上一次结果并给出文案；首次失败就是失败态 + 重试
@MainActor
@Observable
final class RuleService {

    private(set) var rules: [RuleEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// 是否成功拿到过一次（缓存有效性 + 「共 N 条」是否可信）
    private(set) var hasLoaded = false

    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var clientKey: String?

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    /// 进页面时调用：有缓存就不再请求（只有失败 / 从未加载才拉）
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await fetch()
    }

    /// 「重试」/ 手动刷新：无论缓存都重新拉一次
    func refresh() async {
        await fetch()
    }

    /// 内核停止 / 失败 / 换配置：缓存作废，下次进页面重新拉
    func invalidate() {
        rules = []
        hasLoaded = false
        isLoading = false
        // 页面正开着时不能停在「正在读取」：内核确实没跑，如实给失败态 + 重试
        lastError = "内核未运行"
        client = nil
        clientKey = nil
    }

    // MARK: - 读取

    private func fetch() async {
        guard !isLoading else { return }
        guard kernel.phase == .running else {
            lastError = "内核未运行"
            return
        }
        guard let client = apiClient() else {
            lastError = "内核未运行"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            rules = try await client.rules()
            hasLoaded = true
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: - 客户端 / 错误

    /// 端口或 secret 变了就重建客户端（`core-process` §5）
    private func apiClient() -> ClashAPIClient? {
        guard let port = kernel.port, let secret = kernel.secret else { return nil }
        let key = "\(port):\(secret)"
        if let client, clientKey == key { return client }

        let fresh = ClashAPIClient(port: port, secret: secret)
        client = fresh
        clientKey = key
        return fresh
    }

    private static func message(for error: Error) -> String {
        guard let apiError = error as? ClashAPIClient.APIError else {
            return "读取规则失败，请稍后重试"
        }
        return apiError.userMessage
    }
}

#if DEBUG
extension RuleService {
    /// 截图夹具开关：为真时 `applyPreviewRules()` 摆一个「已加载但 0 条」的空态
    static var previewEmpty = false

    /// 截图夹具：不请求内核，摆出几条典型规则（含长域名与三种目标）
    func applyPreviewRules() {
        if Self.previewEmpty {
            rules = []
            hasLoaded = true
            lastError = nil
            return
        }
        rules = [
            RuleEntry(type: "DomainSuffix", payload: "services.googleapis.cn", proxy: "节点选择"),
            RuleEntry(type: "Domain", payload: "fb.example.shop", proxy: "DIRECT"),
            RuleEntry(type: "DomainKeyword", payload: "telegram", proxy: "节点选择"),
            RuleEntry(type: "DomainSuffix", payload: "a-very-long-subdomain-for-truncation.example.com", proxy: "自动选择"),
            RuleEntry(type: "IPCIDR", payload: "192.168.0.0/16", proxy: "DIRECT"),
            RuleEntry(type: "GeoIP", payload: "CN", proxy: "DIRECT"),
            RuleEntry(type: "DomainSuffix", payload: "doubleclick.net", proxy: "REJECT"),
            RuleEntry(type: "Match", payload: "—", proxy: "节点选择")
        ]
        hasLoaded = true
        lastError = nil
    }
}
#endif
