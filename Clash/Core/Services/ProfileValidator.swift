import Foundation
import OSLog

/// 入库前的配置校验：临时 runtime → `mihomo -t`。
///
/// 与 `KernelService` 的启动校验保持同一套注入（`RuntimeConfigBuilder`）：
/// 随机控制端口 / 随机 DNS 端口 / 随机 secret / `tun.enable=false`。
/// 校验只写 `runtime/` 下的临时文件，绝不覆盖正在使用的 `runtime/runtime.yaml`，
/// 也绝不碰 `profiles/<id>.yaml`（用户配置永不改写）。
enum ProfileValidator {

    private static let logger = Logger(subsystem: "com.clash.app", category: "profiles")
    private static let timeout: TimeInterval = 20

    static func validate(
        yamlText: String,
        runtimeDirectory: URL = AppPaths.runtimeDirectory,
        workDirectory: URL = AppPaths.kernelDirectory
    ) async throws {
        let binaryURL = try bundledKernelURL()

        let ports: [Int]
        do {
            ports = try PortAllocator.allocateDistinct(2)
        } catch {
            throw ProfileStoreError.configInvalid(detail: "无法分配校验端口")
        }

        let injected = RuntimeConfigBuilder.Injected(
            controllerPort: ports[0],
            dnsPort: ports[1],
            secret: RuntimeConfigBuilder.makeSecret()
        )

        let tempURL = runtimeDirectory.appending(path: ".validate-\(UUID().uuidString).yaml")
        do {
            try RuntimeConfigBuilder.build(yamlText: yamlText, injected: injected, to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            let detail = (error as? KernelError)?.logDescription ?? "无法生成运行配置"
            throw ProfileStoreError.configInvalid(detail: detail)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let status = await test(binaryURL: binaryURL, configPath: tempURL, workDirectory: workDirectory)
        guard status == 0 else {
            // 只记退出码：mihomo 的报错文本可能回显节点密码
            logger.error("订阅配置未通过 mihomo -t：exit=\(status)")
            throw ProfileStoreError.configInvalid(detail: "mihomo -t exit \(status)")
        }
    }

    // MARK: - 二进制与进程

    /// 包内 `Contents/Resources/Kernel/mihomo`（与 `KernelService` 同一路径规则）
    private static func bundledKernelURL() throws -> URL {
        for subdirectory in ["Resources/Kernel", "Kernel"] {
            if let url = Bundle.main.url(forResource: "mihomo", withExtension: nil, subdirectory: subdirectory),
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        logger.error("包内找不到可执行的 mihomo（bundle=\(Bundle.main.bundlePath, privacy: .public)）")
        throw ProfileStoreError.binaryMissing
    }

    /// `-t` 只看退出码（0 / 非 0 可靠），不解析 stderr 文本
    private static func test(binaryURL: URL, configPath: URL, workDirectory: URL) async -> Int32 {
        await Task.detached(priority: .userInitiated) { () -> Int32 in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["-t", "-d", workDirectory.path, "-f", configPath.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return -1
            }

            // 兜底：`-t` 正常几十毫秒结束；卡住时杀掉，避免导入一直转圈
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return -2
            }

            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus
        }.value
    }
}
