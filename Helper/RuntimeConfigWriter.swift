import Darwin
import Foundation
import Yams

/// helper 侧运行配置的落盘器（协议 v2）。
///
/// 职责只有一件事：把 App 送来的正文**校验后原子写到固定路径**。不启动内核、不解析业务语义、
/// 不接受路径参数——路径永远是 `HelperLayout.runtimeConfigPath`。
///
/// 为什么由 helper 写而不是 App 写：
/// 1. TUN 需要 root，`runtime.yaml` 与内核同属 root，App（普通用户）本来就不该有写权限；
/// 2. 「写配置」和「启内核」在同一个进程里做，中间没有用户态可插入的时间窗。
///
/// 校验边界（`core-process` §4 + 本轮约定）：
/// - 空正文 / 超过 `HelperMaxRuntimeConfigBytes` → 拒绝，不回退到「上一次的配置」
/// - 非 UTF-8 → 拒绝
/// - `Yams.load` 抛错（含重复键）→ 拒绝，错误文案只报类别，不回显 YAML 片段
/// - 顶层必须是映射：数组 / 标量 / 空文档一律拒绝（mihomo 只接受键值对）
enum RuntimeConfigWriter {


    /// 校验并原子写入。`nil` 消息 = 成功。
    static func apply(_ bytes: Data) -> KernelCommandResult {
        guard !bytes.isEmpty else {
            HelperLog.error("拒绝空配置正文")
            return .failure("运行配置为空，无法写入")
        }
        guard bytes.count <= HelperMaxRuntimeConfigBytes else {
            HelperLog.error("拒绝超大配置：\(bytes.count) bytes")
            return .failure("运行配置过大（\(bytes.count / 1024) KB），上限 \(HelperMaxRuntimeConfigBytes / 1024 / 1024) MB")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            HelperLog.error("拒绝非 UTF-8 配置正文")
            return .failure("运行配置不是 UTF-8 文本")
        }

        // 先校验再落盘：写坏一份 root 配置会让内核下次启动直接失败，且 App 读不到日志
        do {
            guard let loaded = try Yams.load(yaml: text) else {
                return .failure("运行配置为空文档，顶层必须是键值对")
            }
            guard loaded is [AnyHashable: Any] else {
                return .failure("运行配置顶层必须是键值对（映射）")
            }
        } catch let error as YamlError {
            HelperLog.error("YAML 解析失败：\(error.localizedDescription)")
            return .failure(parseFailureReason(error))
        } catch {
            HelperLog.error("YAML 解析失败：\(error.localizedDescription)")
            return .failure("运行配置不是合法 YAML")
        }

        do {
            try ensureSupportDirectory()
            try writeAtomically(bytes, to: HelperLayout.runtimeConfigPath)
        } catch {
            HelperLog.error("写入运行配置失败：\(error.localizedDescription)")
            return .failure("写入运行配置失败：\(error.localizedDescription)")
        }

        HelperLog.notice("运行配置已更新 \(bytes.count) bytes")
        return .success()
    }

    // MARK: - 落盘

    /// 目录必须 root:wheel 0755：内核在这里读写 cache.db / geodata，普通用户不可写。
    private static func ensureSupportDirectory() throws {
        let path = HelperLayout.supportDirectory
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: path
        )
    }

    /// 同目录临时文件（0600 root:wheel）→ `rename(2)` 覆盖。
    ///
    /// 先收紧权限再改名，因此目标路径上**不存在**「已可读但还没 0600」的窗口；
    /// `rename` 是同文件系统内的原子替换，内核任何时刻读到的都是完整的一份。
    private static func writeAtomically(_ bytes: Data, to path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let tempPath = directory.appending(path: ".runtime-\(UUID().uuidString).yaml").path
        let fileManager = FileManager.default

        guard fileManager.createFile(atPath: tempPath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeConfigWriteError.tempFileUnavailable
        }

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
            defer { try? handle.close() }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            try? fileManager.removeItem(atPath: tempPath)
            throw error
        }

        // 权限与属主在改名**之前**落定：helper 是 root，这里显式写死 0:0 而不是依赖 umask
        try fileManager.setAttributes(
            [.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: tempPath
        )

        guard rename(tempPath, path) == 0 else {
            let code = errno
            try? fileManager.removeItem(atPath: tempPath)
            throw RuntimeConfigWriteError.renameFailed(code: code)
        }
    }

    /// 只报类别：配置正文里可能有节点密码 / 订阅 token，不能回显
    private static func parseFailureReason(_ error: YamlError) -> String {
        switch error {
        case .duplicatedKeysInMapping:
            "运行配置存在重复键（同一层级同名键出现多次）"
        default:
            "运行配置不是合法 YAML"
        }
    }
}

private enum RuntimeConfigWriteError: LocalizedError {
    case tempFileUnavailable
    case renameFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .tempFileUnavailable:
            "无法创建临时配置文件"
        case .renameFailed(let code):
            "替换运行配置失败（errno \(code)）"
        }
    }
}
