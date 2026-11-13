#if DEBUG
import Foundation

/// 订阅库的 CLI 自检（仅 DEBUG）：`CLASH_PROFILE_HARNESS=<目录>` 时在 UI 起来前跑完整流程并退出。
///
/// 用途：命令行验证「导入 / 重复导入 / 更新 / 失败更新 / 删除」五条链路，
/// 不依赖点菜单栏。配合 `Scripts/check-profile-store.sh` 使用。
@MainActor
enum ProfileStoreHarness {

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLASH_PROFILE_HARNESS"],
              !path.isEmpty else { return }

        let directory = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        )

        var failures = 0
        var finished = false
        Task { @MainActor in
            failures = await run(directory: directory)
            finished = true
        }

        let deadline = Date().addingTimeInterval(240)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        print(finished ? "HARNESS DONE failures=\(failures)" : "HARNESS TIMEOUT")
        exit(finished ? (failures == 0 ? 0 : 1) : 2)
    }

    // MARK: - 流程

    private static func run(directory: URL) async -> Int {
        let environment = ProcessInfo.processInfo.environment
        let store = ProfileStore(directory: directory.appending(path: "profiles", directoryHint: .isDirectory))
        var failures = 0

        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
            if !passed { failures += 1 }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("FAIL 无法创建自检目录")
            return 1
        }

        let source = directory.appending(path: "本地 测试.yaml")
        do {
            try makeYAML(nodeName: "香港 01").write(to: source, atomically: true, encoding: .utf8)
        } catch {
            print("FAIL 无法写测试源文件")
            return 1
        }

        // 1. 本地导入
        print("STEP 1 导入本地配置")
        let first: ProfileEntry
        do {
            first = try await store.importFile(at: source)
        } catch {
            print("FAIL 本地导入抛错：\(error)")
            return 1
        }
        check("本地导入生成记录", store.entry(id: first.id) != nil)
        check("首次导入自动激活", store.activeProfileID == first.id)
        check("yaml 已落盘", FileManager.default.fileExists(atPath: store.yamlURL(for: first.id).path))
        check(
            "yaml 原样保存",
            (try? Data(contentsOf: store.yamlURL(for: first.id))) == (try? Data(contentsOf: source))
        )
        print("ACTIVE \(store.activeProfileID ?? "nil")")

        // 2. 再次导入同一文件 → 新增一条
        print("STEP 2 重复导入同一文件")
        do {
            _ = try await store.importFile(at: source)
        } catch {
            print("FAIL 重复导入抛错：\(error)")
        }
        check("重复导入新增一条", store.entries.count == 2)
        check("激活项不变", store.activeProfileID == first.id)
        print("COUNT \(store.entries.count)")

        // 3. 改源文件后更新
        print("STEP 3 修改源文件后更新")
        let updatedBefore = store.entry(id: first.id)?.updatedAt
        try? makeYAML(nodeName: "香港 02").write(to: source, atomically: true, encoding: .utf8)
        do {
            try await store.update(id: first.id)
        } catch {
            print("FAIL 更新抛错：\(error)")
        }
        let updatedAfter = store.entry(id: first.id)
        let storedYAML = (try? String(contentsOf: store.yamlURL(for: first.id), encoding: .utf8)) ?? ""
        check("更新后 yaml 变了", storedYAML.contains("香港 02"))
        check("updatedAt 变了", updatedAfter?.updatedAt != updatedBefore)
        check("更新后 lastError 清空", updatedAfter?.lastError == nil)

        // 4. URL 导入 + 响应头映射 + UA 回退
        print("STEP 4 URL 导入")
        if let rawURL = environment["CLASH_HARNESS_URL"], let url = URL(string: rawURL) {
            do {
                let probe = try await SubscriptionFetcher.fetch(url: url)
                check("422 后换预设 UA 重试", probe.userAgent.hasPrefix("clash-verge/"), probe.userAgent)

                _ = try? await SubscriptionFetcher.fetch(url: url) // 预热，不影响断言
                let entry = try await store.importURL(rawURL)
                print("URL_NAME \(entry.name)")
                print("URL_HOURS \(entry.autoUpdateHours)")
                print("URL_INFO \(describe(entry.subscriptionInfo))")
                print("URL_WEB \(entry.webPageURL ?? "-")")
                check("Content-Disposition 命名", entry.name == "测试机场", entry.name)
                check("Profile-Update-Interval → autoUpdateHours", entry.autoUpdateHours == 6)
                check(
                    "subscription-userinfo 映射",
                    entry.subscriptionInfo?.download == 2048
                        && entry.subscriptionInfo?.total == 107_374_182_400
                        && entry.subscriptionInfo?.expire == nil,
                    describe(entry.subscriptionInfo)
                )
                check("Profile-Web-Page-Url 入库", entry.webPageURL == "https://example.com/panel")

                // 同 URL 再导入 → 原地更新，不新增
                let countBefore = store.entries.count
                _ = try await store.importURL(rawURL)
                check("同 URL 再导入不新增", store.entries.count == countBefore)
            } catch {
                print("FAIL URL 导入抛错：\(error)")
                failures += 1
            }
        } else {
            print("SKIP URL 导入（未设置 CLASH_HARNESS_URL）")
        }

        // 5. 失败更新：旧 yaml 保留，只写 lastError
        print("STEP 5 失败更新")
        if let rawURL = environment["CLASH_HARNESS_FAIL_URL"] {
            do {
                let flaky = try await store.importURL(rawURL)
                let before = try Data(contentsOf: store.yamlURL(for: flaky.id))
                var threw = false
                do {
                    try await store.update(id: flaky.id)
                } catch {
                    threw = true
                    print("EXPECTED_ERROR \(error)")
                }
                let after = store.entry(id: flaky.id)
                let afterData = try Data(contentsOf: store.yamlURL(for: flaky.id))
                check("失败更新抛出错误", threw)
                check("失败保留旧 yaml", afterData == before)
                check("lastError 有值", after?.lastError != nil, after?.lastError ?? "nil")
                check("失败不推进 updatedAt", after?.updatedAt == flaky.updatedAt)
            } catch {
                print("FAIL 失败更新用例准备抛错：\(error)")
                failures += 1
            }
        } else {
            print("SKIP 失败更新（未设置 CLASH_HARNESS_FAIL_URL）")
        }

        // 5b. 死链导入不留记录
        if let rawURL = environment["CLASH_HARNESS_DEAD_URL"] {
            let countBefore = store.entries.count
            do {
                _ = try await store.importURL(rawURL)
                check("死链导入应失败", false)
            } catch {
                print("EXPECTED_ERROR \(error)")
                check("死链失败不留记录", store.entries.count == countBefore)
            }
        }

        print("INDEX_BEFORE_DELETE")
        print(indexText(at: directory))

        // 5c. 留存入库文件副本，供 shell 再跑一次 `mihomo -t`
        let artifacts = directory.appending(path: "artifacts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for entry in store.entries {
            let source = store.yamlURL(for: entry.id)
            let destination = artifacts.appending(path: "\(entry.id).yaml")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        print("ARTIFACTS \(artifacts.path)")

        // 6. 删除激活项 → 切到另一条；删空 → active 清空
        print("STEP 6 删除激活项")
        do {
            let change = try store.delete(id: first.id)
            check("删除激活项后切到另一条", change == .switched)
            check("active 已切走", store.activeProfileID != first.id)
            check("文件已删除", !FileManager.default.fileExists(atPath: store.yamlURL(for: first.id).path))

            for entry in store.entries {
                _ = try store.delete(id: entry.id)
            }
            check("删空后 active 为空", store.activeProfileID == nil)
            check("删空后列表为空", store.entries.isEmpty)
        } catch {
            print("FAIL 删除抛错：\(error)")
            failures += 1
        }

        print("INDEX_AFTER_DELETE")
        print(indexText(at: directory))
        return failures
    }

    // MARK: - 工具

    private static func describe(_ info: ProfileSubscriptionInfo?) -> String {
        guard let info else { return "nil" }
        return "upload=\(info.upload.map(String.init) ?? "nil") "
            + "download=\(info.download.map(String.init) ?? "nil") "
            + "total=\(info.total.map(String.init) ?? "nil") "
            + "expire=\(info.expire.map(String.init) ?? "nil")"
    }

    private static func indexText(at directory: URL) -> String {
        let url = directory.appending(path: "profiles/index.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "(无法读取 index.json)"
    }

    /// 测试配置刻意带上会被收紧的键（`allow-lan: true`、`dns.listen: 0.0.0.0`）
    private static func makeYAML(nodeName: String) -> String {
        """
        mixed-port: 7890
        allow-lan: true
        mode: rule
        log-level: info
        dns:
          enable: true
          listen: 0.0.0.0:1053
        proxies:
          - name: \(nodeName)
            type: ss
            server: 127.0.0.1
            port: 8388
            cipher: aes-128-gcm
            password: test-password
        proxy-groups:
          - name: 节点选择
            type: select
            proxies:
              - \(nodeName)
        rules:
          - MATCH,节点选择

        """
    }
}
#endif
