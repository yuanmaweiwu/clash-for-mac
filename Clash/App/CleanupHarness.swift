#if DEBUG
import Foundation

/// 「彻底清理可恢复」自检（仅 DEBUG）：`CLASH_CLEANUP_HARNESS=1` + `CLASH_DATA_ROOT=/tmp/cleanup-test`
/// 时，用临时数据根造一份假用户数据，调 `performFullCleanup()`，断言：
///
/// 1. 数据根与缓存目录都进了废纸篓（`~/.Trash` 里能找到），而不是被 `removeItem` 抹掉
/// 2. 真实数据根（`~/Library/Application Support/Clash`）的 mtime 不变
/// 3. 返回值是 `nil`（成功）
///
/// 没有 `CLASH_DATA_ROOT`（或它不在临时目录下）时**直接拒绝运行**：
/// 这个夹具会真的清数据，绝不允许碰真实用户目录。
@MainActor
enum CleanupHarness {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CLASH_CLEANUP_HARNESS"] == "1"
    }

    static func runIfRequested(model: PanelPreviewModel) {
        guard isRequested else { return }
        Task { @MainActor in
            let failures = await run(model: model)
            print(failures == 0 ? "CLEANUP DONE failures=0" : "CLEANUP DONE failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: - 流程

    private static func run(model: PanelPreviewModel) async -> Int {
        guard let root = AppPaths.dataRootOverride else {
            print("FAIL CLEANUP 缺少 CLASH_DATA_ROOT：本夹具只允许在临时数据根上跑")
            return 1
        }
        guard isTemporary(root) else {
            print("FAIL CLEANUP CLASH_DATA_ROOT=\(root.path) 不在临时目录下，拒绝运行")
            return 1
        }
        guard AppPaths.supportDirectory.path == root.standardizedFileURL.path else {
            print("FAIL CLEANUP supportDirectory=\(AppPaths.supportDirectory.path) 未跟随 CLASH_DATA_ROOT")
            return 1
        }

        var failures = 0
        let realRoot = realSupportDirectory
        let realBefore = modificationDate(of: realRoot)
        print("CLEANUP 数据根=\(root.path) 真实数据根存在=\(FileManager.default.fileExists(atPath: realRoot.path))")

        // 造一份「有订阅、有设置、有缓存」的假用户数据
        seedDataRoot(root)
        failures += report("seeded", FileManager.default.fileExists(atPath: AppPaths.profilesIndexURL.path))

        // 真实目录上一次 mtime，用来证明夹具没碰它
        let returned = await model.performFullCleanup()
        failures += report("cleanup-returned-nil", returned == nil, returned ?? "nil（成功）")

        let fileManager = FileManager.default
        failures += report("data-root-gone", !fileManager.fileExists(atPath: root.path))
        failures += report("caches-gone", !fileManager.fileExists(atPath: AppPaths.cachesDirectory.path))

        // 废纸篓取证：`trashItem` 返回的 URL 必须在废纸篓里、且条目可读（能还原）
        let trashed = model.cleanupTrashedURLs
        failures += report("trashed-count", trashed.count == 2, "\(trashed.map(\.path))")
        let trash = trashDirectory
        for url in trashed {
            let inTrash = url.path.hasPrefix(trash.path + "/")
            let readable = (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
            failures += report("trashed \(url.lastPathComponent)", inTrash && readable, "\(url.path)")
        }

        // 最强的验收：真的从废纸篓还原回来，内容完整，再删掉（只在 /tmp 里）
        if let dataRootInTrash = trashed.first(where: {
            $0.lastPathComponent == root.lastPathComponent
                || $0.lastPathComponent.hasPrefix(root.lastPathComponent + " ")
        }) {
            do {
                try fileManager.moveItem(at: dataRootInTrash, to: root)
                let indexRestored = fileManager.fileExists(atPath: AppPaths.profilesIndexURL.path)
                let settingsRestored = fileManager.fileExists(atPath: AppPaths.settingsURL.path)
                failures += report("restore-from-trash", indexRestored && settingsRestored,
                                   "index=\(indexRestored) settings=\(settingsRestored)")
                print("CLEANUP 已从废纸篓还原到 \(root.path)（随后删除）")
                try? fileManager.removeItem(at: root)
            } catch {
                failures += report("restore-from-trash", false, "\(error.localizedDescription)")
            }
        }
        // 缓存条目不需要还原，直接清掉，避免每次基准都往废纸篓堆东西
        for url in trashed where url.path != root.path && !url.lastPathComponent.hasPrefix(root.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        // 真实数据根 mtime 必须不变（存在才比较）
        let realAfter = modificationDate(of: realRoot)
        if realBefore != nil || realAfter != nil {
            failures += report(
                "real-root-mtime",
                realBefore == realAfter,
                "\(realBefore?.description ?? "nil") → \(realAfter?.description ?? "nil")"
            )
        } else {
            print("SKIP real-root-mtime 真实数据根不存在（已由用户清理）")
        }
        return failures
    }

    // MARK: - 造数据

    private static func seedDataRoot(_ root: URL) {
        let fileManager = FileManager.default
        let files: [(String, String)] = [
            ("profiles/index.json", "{\"version\":1,\"entries\":[],\"activeProfileID\":null}"),
            ("profiles/fixture.yaml", "proxies: []\n"),
            ("settings.json", "{\"mixedPort\":7890}"),
            ("runtime/runtime.yaml", "mixed-port: 7890\n"),
            ("logs/clash-19700101.log", "fixture\n"),
            ("kernel/mihomo", "fixture（不是真内核）\n"),
            ("kernel/VERSION", "v0.0.0-fixture\n"),
            ("Caches/fixture.bin", "cache\n")
        ]
        for (relative, text) in files {
            let url = root.appending(path: relative)
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }

    // MARK: - 工具

    private static var realSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "Clash", directoryHint: .isDirectory)
    }

    private static var trashDirectory: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)
    }

    /// 只允许 `/tmp`、`/private/tmp`、`/var/folders/…`（`NSTemporaryDirectory`）下的路径
    private static func isTemporary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let candidates = [
            "/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/",
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        ]
        return candidates.contains { path.hasPrefix($0) }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }
}
#endif
