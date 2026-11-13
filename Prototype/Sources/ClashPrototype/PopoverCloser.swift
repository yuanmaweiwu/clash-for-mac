import AppKit

/// `MenuBarExtra` 没有公开的关闭 API，Esc 在首层时关掉当前 key window（即浮层本身）。
@MainActor
enum PopoverCloser {
    static func close() {
        NSApp.keyWindow?.close()
    }
}
