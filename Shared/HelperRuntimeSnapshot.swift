import Foundation

/// helper 侧运行时自检（`ping` 的返回值）。
///
/// 为什么塞进 `ping` 而不是新开一个 XPC 方法：已经装好的旧 helper（v2）只认 `ping`，
/// 新增 selector 会让旧 helper 直接报错并断开连接——「想看状态」反而先把连接弄死。
/// `ping` 的返回类型仍是 `String`，**旧 helper 返回纯版本号也能解析**（附加字段视为未知）。
///
/// 线上格式：`2 kernel=1 config=1 dir=1`；App 侧只按 `key=1/0` 读，读不到当未知。
struct HelperRuntimeSnapshot: Sendable, Equatable {

    let version: Int
    /// `HelperLayout.kernelToolPath` 是否为可执行文件
    let kernelBinaryPresent: Bool?
    /// `HelperLayout.runtimeConfigPath` 是否存在
    let runtimeConfigPresent: Bool?
    /// 运行目录是否存在（root 视角）
    let supportDirectoryPresent: Bool?

    var wireValue: String {
        var parts = ["\(version)"]
        if let kernelBinaryPresent { parts.append("kernel=\(kernelBinaryPresent ? 1 : 0)") }
        if let runtimeConfigPresent { parts.append("config=\(runtimeConfigPresent ? 1 : 0)") }
        if let supportDirectoryPresent { parts.append("dir=\(supportDirectoryPresent ? 1 : 0)") }
        return parts.joined(separator: " ")
    }

    /// 缺哪些运行时（空 = 齐全或未知）
    var missingComponents: [String] {
        var missing: [String] = []
        if kernelBinaryPresent == false { missing.append("内核文件") }
        if runtimeConfigPresent == false { missing.append("运行配置") }
        if supportDirectoryPresent == false { missing.append("运行目录") }
        return missing
    }
}

extension HelperRuntimeSnapshot {

    /// 宽松解析：第一个字段必须是版本号，其余按 `key=1/0` 读取，不认识的键忽略
    init?(wireValue: String) {
        let tokens = wireValue.split(separator: " ").map(String.init)
        guard let first = tokens.first, let version = Int(first) else { return nil }
        self.version = version

        var fields: [String: Bool] = [:]
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1] == "1"
        }
        kernelBinaryPresent = fields["kernel"]
        runtimeConfigPresent = fields["config"]
        supportDirectoryPresent = fields["dir"]
    }

    /// helper 侧采集（跑在 root，能看见 `/Library/...`）
    static func current() -> HelperRuntimeSnapshot {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(
            atPath: HelperLayout.supportDirectory,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue

        return HelperRuntimeSnapshot(
            version: HelperVersion,
            kernelBinaryPresent: fileManager.isExecutableFile(atPath: HelperLayout.kernelToolPath),
            runtimeConfigPresent: fileManager.fileExists(atPath: HelperLayout.runtimeConfigPath),
            supportDirectoryPresent: directoryExists
        )
    }
}
