import Foundation
import OSLog

/// Helper 安装 / 卸载的错误分类（UI 必须能区分，见 `core-process` §7 的 `permissionDenied`）。
enum HelperInstallError: Error, Equatable, Sendable {
    /// 包内没有 helper 产物（构建漏了 Copy 阶段）
    case helperMissingInBundle
    /// 用户目录里还没有内核（ADR-0012：运行时下载，安装前必须先准备好）
    case kernelNotDownloaded
    /// 用户在密码框点了取消（osascript 返回 -128）
    case userCancelled
    /// 脚本本身失败：`detail` 取 stderr 末行
    case installFailed(detail: String)
    /// 文件都到位了，但 launchd 没把 job 跑起来
    case daemonNotRunning
    /// 卸载没走完（文件或 plist 仍在）
    case uninstallFailed(detail: String)

    /// 面向用户的一句话
    var userMessage: String {
        switch self {
        case .helperMissingInBundle:
            "安装包不完整（缺少特权组件），请重新构建应用"
        case .kernelNotDownloaded:
            "内核尚未下载完成，请先点「连接」完成下载后重试"
        case .userCancelled:
            "已取消管理员授权，TUN 需要该组件才能开启"
        case .installFailed(let detail):
            "组件安装失败：\(detail)"
        case .daemonNotRunning:
            "组件已拷贝但未运行，请重启电脑后重试"
        case .uninstallFailed(let detail):
            "组件卸载未完成：\(detail)"
        }
    }

    var logDescription: String {
        switch self {
        case .helperMissingInBundle: "helperMissingInBundle（App 包内缺 com.clash.helper）"
        case .kernelNotDownloaded: "kernelNotDownloaded（用户目录缺 mihomo）"
        case .userCancelled: "userCancelled（用户取消授权 -128）"
        case .installFailed(let detail): "installFailed（\(detail)）"
        case .daemonNotRunning: "daemonNotRunning（launchctl print 失败）"
        case .uninstallFailed(let detail): "uninstallFailed（\(detail)）"
        }
    }
}

/// 特权组件安装 / 卸载（`adr/0008`：不用 `SMAppService`，手动装 LaunchDaemon）。
///
/// 一次 `osascript … with administrator privileges` 弹系统密码框，脚本以 root 完成
/// 拷贝 → 写 plist → `launchctl bootstrap`。**脚本内容固定、路径固定、逐条 `&&`**，
/// 内核与 geodata 从用户已下载的 `~/Library/Application Support/Clash/kernel/` 拷入
/// （ADR-0012），不给任何自由参数。
enum HelperInstaller {

    private static let logger = Logger(subsystem: "com.clash.app", category: "helper")
    private static let osascriptPath = "/usr/bin/osascript"
    private static let launchctlPath = "/bin/launchctl"
    private static let shellPath = "/bin/sh"

    // MARK: - 状态

    /// 三个条件同时成立才算装好：helper 可执行、plist 在、launchd 里能查到 job。
    /// （App 启动时据此决定是否给「需要安装组件」的引导）
    static var isInstalled: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: HelperLayout.helperToolPath)
            && fileManager.fileExists(atPath: HelperLayout.daemonPlistPath)
            && isDaemonLoaded
    }

    /// `launchctl print system/com.clash.helper` 退出码 0 = job 已加载
    static var isDaemonLoaded: Bool {
        run(launchctlPath, ["print", "system/" + HelperLayout.machServiceName]).status == 0
    }

    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appending(path: HelperLayout.bundledHelperRelativePath)
    }

    /// 内核来源改为用户目录（ADR-0012）：包内不再带二进制
    static var kernelSourceURL: URL {
        AppPaths.kernelBinaryURL
    }

    /// geodata 与内核同目录，安装时一起拷进 helper 运行目录
    static var geodataSourceDirectory: URL {
        AppPaths.kernelDirectory
    }

    // MARK: - 安装

    /// 弹一次管理员授权并安装。
    ///
    /// 升级场景下**不要**在内核运行中调用：脚本会先 `bootout` 再覆盖二进制，
    /// 覆盖一个仍被 mihomo 打开的二进制会 `ETXTBSY` 失败（先 `stopKernel`）。
    static func install() async throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else {
            logger.error("包内缺少 helper：\(bundledHelperURL.path, privacy: .public)")
            throw HelperInstallError.helperMissingInBundle
        }
        guard fileManager.isExecutableFile(atPath: kernelSourceURL.path) else {
            logger.error("用户目录缺少内核：\(kernelSourceURL.path, privacy: .public)")
            throw HelperInstallError.kernelNotDownloaded
        }

        let output = try await runElevated(script: installScript(), action: "安装")
        logger.notice("安装脚本输出：\(output, privacy: .public)")

        guard output.contains("OK") else {
            throw HelperInstallError.installFailed(detail: clipped(output))
        }
        guard isInstalled else {
            logger.error("安装后 launchd 未加载 job（bootstrap 成功但 print 失败）")
            throw HelperInstallError.daemonNotRunning
        }
        logger.notice("helper 已安装并运行")
    }

    // MARK: - 卸载

    /// `bootout` → 删 plist → 删 helper / mihomo / 运行目录，同样一次授权。
    static func uninstall() async throws {
        do {
            _ = try await runElevated(script: uninstallScript(), action: "卸载")
        } catch HelperInstallError.installFailed(let detail) {
            throw HelperInstallError.uninstallFailed(detail: detail)
        }

        let fileManager = FileManager.default
        let leftovers = [HelperLayout.helperToolPath, HelperLayout.daemonPlistPath]
            .filter { fileManager.fileExists(atPath: $0) }
        guard leftovers.isEmpty else {
            throw HelperInstallError.uninstallFailed(detail: "残留 \(leftovers.joined(separator: "、"))")
        }
        logger.notice("helper 已卸载")
    }

    // MARK: - 脚本（固定内容，供审阅 / 自检）

    /// 安装脚本全文。helper 路径来自 `HelperLayout`；内核与 geodata 来自用户目录
    /// （ADR-0012，路径在生成时写死，脚本仍不接受参数）。
    ///
    /// `set -eu` 已经保证「任何一步失败即中止」，所以用逐行命令（可读、可加条件），
    /// 不再用一长串 `&&`。重复内容用 `cmp -s` 跳过：重装时不用再拷 56MB 内核，
    /// 也避免覆盖仍被 mihomo 打开的文件（`ETXTBSY`）。
    /// - Parameter bundleURL: 只为自检 / 审阅可注入，正常运行不传。
    static func installScript(bundleURL: URL = Bundle.main.bundleURL) -> String {
        let helperSource = bundleURL.appending(path: HelperLayout.bundledHelperRelativePath).path
        let kernelSource = kernelSourceURL.path
        let kernelSourceDirectory = geodataSourceDirectory.path

        return """
        #!/bin/sh
        # Clash 特权组件安装（由 App 生成，osascript 以管理员身份执行；固定路径，不接受参数）
        set -eu
        umask 022

        HELPER_SRC=\(shellQuoted(helperSource))
        KERNEL_SRC=\(shellQuoted(kernelSource))
        KERNEL_SRC_DIR=\(shellQuoted(kernelSourceDirectory))
        HELPER_DST=\(shellQuoted(HelperLayout.helperToolPath))
        KERNEL_DST=\(shellQuoted(HelperLayout.kernelToolPath))
        SUPPORT_DIR=\(shellQuoted(HelperLayout.supportDirectory))
        PLIST=\(shellQuoted(HelperLayout.daemonPlistPath))

        PLIST_BODY=\(shellQuoted(launchDaemonPlist))

        # 内容一致就不覆盖：重装省掉大文件拷贝，也不碰正在运行的可执行文件
        copy_if_changed() {
          if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi
          cp -f "$1" "$2"
        }

        test -f "$HELPER_SRC"
        test -f "$KERNEL_SRC"
        mkdir -p /Library/PrivilegedHelperTools
        mkdir -p "$SUPPORT_DIR"
        chown root:wheel /Library/PrivilegedHelperTools "$SUPPORT_DIR"
        chmod 0755 /Library/PrivilegedHelperTools "$SUPPORT_DIR"
        launchctl bootout system/\(HelperLayout.machServiceName) 2>/dev/null || true
        copy_if_changed "$HELPER_SRC" "$HELPER_DST"
        copy_if_changed "$KERNEL_SRC" "$KERNEL_DST"
        for f in geoip.metadb geosite.dat; do
          if [ -f "$KERNEL_SRC_DIR/$f" ]; then copy_if_changed "$KERNEL_SRC_DIR/$f" "$SUPPORT_DIR/$f"; fi
        done
        chmod 0644 "$SUPPORT_DIR"/geoip.metadb "$SUPPORT_DIR"/geosite.dat 2>/dev/null || true
        chown root:wheel "$HELPER_DST" "$KERNEL_DST"
        chmod 0755 "$HELPER_DST" "$KERNEL_DST"
        printf '%s\\n' "$PLIST_BODY" > "$PLIST"
        chown root:wheel "$PLIST"
        chmod 0644 "$PLIST"
        plutil -lint "$PLIST" > /dev/null
        launchctl bootstrap system "$PLIST"
        launchctl enable system/\(HelperLayout.machServiceName)
        echo 'OK'
        """
    }

    /// 卸载脚本全文（逆操作，顺序不能换：先 bootout 再删文件）
    static func uninstallScript() -> String {
        """
        #!/bin/sh
        # Clash 特权组件卸载（由 App 生成，osascript 以管理员身份执行；固定路径）
        set -eu
        umask 022

        PLIST=\(shellQuoted(HelperLayout.daemonPlistPath))

        (launchctl bootout system/\(HelperLayout.machServiceName) 2>/dev/null || true)
        rm -f "$PLIST"
        rm -f \(shellQuoted(HelperLayout.helperToolPath))
        rm -f \(shellQuoted(HelperLayout.kernelToolPath))
        rm -rf \(shellQuoted(HelperLayout.supportDirectory))
        echo 'OK'
        """
    }

    /// LaunchDaemon 定义（唯一源；`launchctl` 需要 root:wheel 0644）
    static var launchDaemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(HelperLayout.machServiceName)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(HelperLayout.helperToolPath)</string>
        \t</array>
        \t<key>MachServices</key>
        \t<dict>
        \t\t<key>\(HelperLayout.machServiceName)</key>
        \t\t<true/>
        \t</dict>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>5</integer>
        \t<key>StandardOutPath</key>
        \t<string>\(HelperLayout.helperLogPath)</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(HelperLayout.helperLogPath)</string>
        </dict>
        </plist>
        """
    }

    // MARK: - osascript

    /// 把脚本落到 0700 临时文件，再让 `osascript` 以管理员身份 `sh` 它。
    ///
    /// 不把脚本文本塞进 AppleScript 字符串：那样要转义两层引号，审阅时看不清真实命令。
    private static func runElevated(script: String, action: String) async throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "com.clash.helper-\(UUID().uuidString).sh")
        do {
            try Data(script.utf8).write(to: scriptURL)
        } catch {
            throw HelperInstallError.installFailed(detail: "无法写入临时脚本：\(error.localizedDescription)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let command = "/bin/sh " + shellQuoted(scriptURL.path)
        let appleScript = "do shell script " + appleScriptQuoted(command) + " with administrator privileges"

        let result = await Task.detached(priority: .userInitiated) {
            run(osascriptPath, ["-e", appleScript])
        }.value

        guard result.status == 0 else {
            let detail = clipped(result.output)
            if detail.contains("(-128)") {
                logger.notice("\(action, privacy: .public)：用户取消授权")
                throw HelperInstallError.userCancelled
            }
            logger.error("\(action, privacy: .public)失败 exit=\(result.status)：\(detail, privacy: .public)")
            throw HelperInstallError.installFailed(detail: detail)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 进程与转义

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 单引号包裹：脚本里所有路径都用它，`$`/空格/中文都不用再操心
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量（只转义 `\` 与 `"`）
    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastLine = trimmed.split(separator: "\n").last.map(String.init) else { return "未知错误" }
        return lastLine.count > 300 ? String(lastLine.prefix(300)) + "…" : lastLine
    }
}
