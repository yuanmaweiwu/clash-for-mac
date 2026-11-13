import Foundation

/// 原子写：同目录临时文件 → 0600 → rename 覆盖。
///
/// `index.json` 与 `profiles/<id>.yaml` 都走这里，避免出现半截文件。
enum AtomicFile {

    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: tempURL.path
            )

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    static func write(text: String, to url: URL, permissions: Int = 0o600) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
    }
}
