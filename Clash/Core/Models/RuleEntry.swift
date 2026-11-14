import Foundation

/// 一条 mihomo 规则（`GET /rules`，`docs/02-UI-SPEC.md` §4.11）。
///
/// 内核给的是配置顺序的数组，字段即 `{type, payload, proxy}`（另有 `index` / `size` /
/// `extra` 等运行期信息，面板不用）。类型是驼峰原文（`DomainSuffix`），
/// 展示统一走 `canonicalType` 还原成配置写法（`DOMAIN-SUFFIX`）。
struct RuleEntry: Decodable, Sendable, Equatable {

    /// 内核原始类型，例如 `DomainSuffix` / `IPCIDR` / `Match`
    let type: String
    /// 规则内容：域名、CIDR、规则集名…
    let payload: String
    /// 命中后的目标：策略组名 / `DIRECT` / `REJECT`
    let proxy: String

    /// 徽标文案：配置写法的大写连字符形式
    var canonicalType: String { RuleTypeName.canonical(type) }
}

/// 内核类型 → 配置写法。表里没有的走驼峰拆词兜底，避免出现 `DOMAINSUFFIX` 这种。
enum RuleTypeName {

    private static let table: [String: String] = [
        "Domain": "DOMAIN",
        "DomainSuffix": "DOMAIN-SUFFIX",
        "DomainKeyword": "DOMAIN-KEYWORD",
        "DomainRegex": "DOMAIN-REGEX",
        "GeoSite": "GEOSITE",
        "GeoIP": "GEOIP",
        "IPCIDR": "IP-CIDR",
        "IPCIDR6": "IP-CIDR6",
        "SrcIPCIDR": "SRC-IP-CIDR",
        "SrcPort": "SRC-PORT",
        "DstPort": "DST-PORT",
        "Network": "NETWORK",
        "ProcessName": "PROCESS-NAME",
        "ProcessPath": "PROCESS-PATH",
        "RuleSet": "RULE-SET",
        "Match": "MATCH",
        "And": "AND",
        "Or": "OR",
        "Not": "NOT",
        "Script": "SCRIPT",
        "InboundPort": "INBOUND-PORT"
    ]

    static func canonical(_ raw: String) -> String {
        if let known = table[raw] { return known }
        var result = ""
        for character in raw {
            if character.isUppercase, !result.isEmpty, result.last != "-" {
                result.append("-")
            }
            result.append(character)
        }
        return result.uppercased()
    }
}
