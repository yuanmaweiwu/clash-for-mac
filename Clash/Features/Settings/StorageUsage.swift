import Foundation

/// 设置页「存储」一行的体积状态。
///
/// 计算是异步的（`du` 语义要递归整棵树）；`@State` 里只放结果，
/// 绝不在 SwiftUI body 里同步扫盘——`kernel/` 里可能有一份几百 MB 的内核与 geodata。
enum StorageSizeState: Equatable, Sendable {
    case loading
    case bytes(Int64)
    /// 目录存在但无权读（典型：`/Library/Application Support/ClashHelper` 里的 0600 文件）
    case unavailable(String)
}

/// 三个受管目录：应用数据 / 缓存 / 特权组件数据。
struct StorageTarget: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case appData
        case caches
        case helper
    }

    let kind: Kind

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .appData: "应用数据"
        case .caches: "缓存"
        case .helper: "特权组件数据"
        }
    }

    var url: URL {
        switch kind {
        case .appData: AppPaths.supportDirectory
        case .caches: AppPaths.cachesDirectory
        case .helper: URL(fileURLWithPath: HelperLayout.supportDirectory, isDirectory: true)
        }
    }

    /// 展示用短路径：`~/Library/Application Support/Clash`
    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// 目录体积探测：递归求和 `totalFileAllocatedSize`（与 `du -sh` 的块占用口径一致）。
enum StorageUsageProbe {

    /// 特权组件只有装过才展示（未装时那个目录不存在，列一行 0 B 反而误导）
    static func targets(includeHelper: Bool) -> [StorageTarget] {
        var kinds: [StorageTarget.Kind] = [.appData, .caches]
        if includeHelper { kinds.append(.helper) }
        return kinds.map { StorageTarget(kind: $0) }
    }

    static func measure(_ url: URL) async -> StorageSizeState {
        await Task.detached(priority: .utility) {
            measureSynchronously(url)
        }.value
    }

    /// 同步实现（只在后台线程调用；自检也可直接调）。
    static func measureSynchronously(_ url: URL) -> StorageSizeState {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .bytes(0)
        }
        guard isDirectory.boolValue else { return .bytes(0) }
        // root 目录（0755）能列；0600 文件靠 lstat 取大小，不需要读内容。
        guard fileManager.isReadableFile(atPath: url.path) else {
            return .unavailable("需管理员权限")
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ]
        var total: Int64 = 0
        var unreadable = 0

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            return .unavailable("需管理员权限")
        }

        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                unreadable += 1
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
        }

        // 一个字节都读不到且出过错：报权限，不报 0（0 会被当成「空目录」）
        if total == 0, unreadable > 0 {
            return .unavailable("需管理员权限")
        }
        return .bytes(total)
    }
}
