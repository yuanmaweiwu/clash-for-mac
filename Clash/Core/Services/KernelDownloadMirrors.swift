import Foundation

/// 内核 / geodata 的下载源策略（`adr/0012`）。
///
/// `.automatic` 是默认值：先直连 GitHub，再依次尝试预置镜像，成功一个即停。
/// 之所以敢默认用第三方镜像：**每个源下载完都要过 committed 的 SHA256**，
/// 镜像只能转发字节、无法替换内核内容；不匹配立即删除并换下一个源。
enum KernelDownloadMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 直连 → 预置镜像（推荐）
    case automatic
    /// 只用 GitHub 原始地址
    case direct
    /// 只用用户填的前缀（前缀 + 原始 URL 原样拼接）
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动（推荐）"
        case .direct: "仅直连"
        case .custom: "自定义…"
        }
    }
}

/// 预置下载镜像清单。
///
/// **这些都是第三方服务**：可能限速、失效或下线；可随时增删，不需要改下载逻辑。
/// 安全边界在 `KernelProvisioner`：内核必须与 `Resources/Kernel/SHA256` 一致，
/// geodata 也走同一组源，但只信任 GitHub 官方仓库的内容（镜像无法替换内核）。
enum KernelDownloadMirrors {

    /// 原样拼在原始 GitHub URL 前面（前缀自带结尾 `/`）。
    static let presets = [
        "https://gh-proxy.com/",
        "https://ghproxy.net/"
    ]

    /// 单次尝试的空闲超时（秒）：直连失败时不能让用户等太久
    static let attemptTimeout: TimeInterval = 10

    /// 按模式展开成有序候选列表；`""` 表示直连 GitHub
    static func candidates(mode: KernelDownloadMode, customPrefix: String = "") -> [String] {
        let custom = customPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .automatic:
            return [""] + presets
        case .direct:
            return [""]
        case .custom:
            return [custom.isEmpty ? "" : custom]
        }
    }

    /// 日志 / 文案用的源名
    static func displayName(for prefix: String) -> String {
        prefix.isEmpty ? "直连" : prefix
    }
}

/// 实际生效的下载源选择：环境变量（排障 / 自检）优先于 `settings.json`。
///
/// - `CLASH_KERNEL_DOWNLOAD_MODE`：`automatic` / `direct` / `custom`
/// - `CLASH_KERNEL_MIRROR`：直接指定自定义前缀（隐含 `custom`）
struct KernelDownloadSelection: Equatable, Sendable {

    static let modeEnvironmentKey = "CLASH_KERNEL_DOWNLOAD_MODE"
    static let mirrorEnvironmentKey = "CLASH_KERNEL_MIRROR"

    var mode: KernelDownloadMode
    var customPrefix: String

    var sources: [String] {
        KernelDownloadMirrors.candidates(mode: mode, customPrefix: customPrefix)
    }

    /// 读 `settings.json` 而不构造 `SettingsStore`：下载可能在主线程外触发，
    /// 也绝不能因为读设置而写盘
    static func resolve() -> KernelDownloadSelection {
        let environment = ProcessInfo.processInfo.environment

        if let mirror = environment[mirrorEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !mirror.isEmpty {
            return KernelDownloadSelection(mode: .custom, customPrefix: mirror)
        }

        let environmentMode: KernelDownloadMode? = {
            guard let raw = environment[modeEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return KernelDownloadMode(rawValue: raw)
        }()

        struct Stored: Decodable {
            let kernelDownloadMode: KernelDownloadMode?
            let customMirrorPrefix: String?
        }

        let data = try? Data(contentsOf: AppPaths.settingsURL)
        let stored = data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        return KernelDownloadSelection(
            mode: environmentMode ?? stored?.kernelDownloadMode ?? .automatic,
            customPrefix: (stored?.customMirrorPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
