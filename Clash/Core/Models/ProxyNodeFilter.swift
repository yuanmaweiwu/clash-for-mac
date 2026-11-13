import Foundation

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

    /// 内核合成的内置策略：合法选项，永不过滤（大小写与内核返回一致）
    static let builtinNames: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"
    ]

    /// 是否为需要丢弃的信息节点
    static func isInfoNode(_ name: String) -> Bool {
        if builtinNames.contains(name) { return false }
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 关键词拼成一条正则（`a|b|c`）；关键词里没有正则特殊字符，直接拼接即可
    private static let pattern = infoKeywords.joined(separator: "|")
}
