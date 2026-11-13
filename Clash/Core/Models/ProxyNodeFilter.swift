import Foundation
import OSLog

/// 机场「信息节点」过滤（启发式）。
///
/// 真实订阅里常把到期时间 / 流量用量 / 官网地址做成一串**假节点**塞进组里
/// （如「到期时间：不限时」「已用：103.09G，总共：128.00G」）。它们长得跟正常节点一样，
/// 甚至会被组默认选中——用户一旦选中，流量就被指到一个根本不通的服务器。
///
/// 所以这里按名字关键词把它们从**展示与可选项**里剔除；内核配置本身不动，
/// 也不影响组名、真实节点与内置策略。
///
/// 名称匹配是启发式而非白名单：机场命名千奇百怪，误杀风险与漏网风险都在。
/// 规则集中在这一处常量，后续要做成设置项（开关 + 自定义关键词）只改这里。
enum ProxyNodeFilter {

    /// 名字命中任意一条即视为信息节点（中英文覆盖；匹配时不区分大小写）
    static let infoKeywords = [
        "到期", "过期", "流量", "剩余", "已用", "总共", "官网", "订阅", "重置",
        "套餐", "客服", "网址", "群组", "邀请",
        "expire", "traffic", "website"
    ]

    /// 内核合成的内置策略：合法选项，永不过滤（大小写与内核返回一致）。
    ///
    /// **单一来源**：连接链路的「节点」判定（`ConnectionEntry.node`）也读这一份，
    /// 两处口径必须一致，否则会出现「组里算内置、连接里当节点」。
    static let builtinNames: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"
    ]

    /// 正则只编译一次：`makeGroup` 对每个组每个节点都会问一次，
    /// 一次 `/proxies` 刷新上千次调用；以前每次 `range(of:options:.regularExpression)` 都重编译。
    private static let infoRegex: NSRegularExpression? = {
        let pattern = infoKeywords.joined(separator: "|")
        #if DEBUG
        debugCompileCount += 1
        Logger(subsystem: "com.clash.app", category: "proxies")
            .debug("ProxyNodeFilter 关键词正则已编译（进程内仅一次）")
        #endif
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    #if DEBUG
    /// 自检用：关键词正则的编译次数（正常恒为 1）
    nonisolated(unsafe) private(set) static var debugCompileCount = 0
    #endif

    /// 是否为需要丢弃的信息节点
    static func isInfoNode(_ name: String) -> Bool {
        if builtinNames.contains(name) { return false }
        guard let infoRegex else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return infoRegex.firstMatch(in: name, options: [], range: range) != nil
    }
}
