#if DEBUG
import AppKit
import SwiftUI

/// 无人值守的视觉走查夹具（仅 Debug 编译，不进入正式启动路径）。
///
/// 用法：
/// ```
/// CLASH_PREVIEW_PAGE=root-double CLASH_SCRIM_VARIANT=b \
///   /path/to/Clash.app/Contents/MacOS/Clash
/// ```
/// 会在主屏固定位置摆出一个与正式面板同尺寸的透明浮层，并把屏幕坐标打到标准输出
/// （`CLASH_PREVIEW_REGION x,y,w,h`），外部用 `screencapture -R` 抓「真实材质 + 真实壁纸」。
///
/// 只服务截图与间距核对：不启动内核、不写系统代理、不读写用户配置（订阅列表用只读快照）。
@MainActor
enum UIPreviewHarness {

    /// 面板与屏幕边缘的呼吸：避开菜单栏与 Dock
    private static let screenInset: CGFloat = 60
    private static var windows: [NSWindow] = []

    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let page = environment["CLASH_PREVIEW_PAGE"] else { return false }

        if let variant = environment["CLASH_SCRIM_VARIANT"] {
            Theme.scrimStyle = ScrimStyle(rawValue: variant) ?? .balanced
        }
        if let appearance = environment["CLASH_PREVIEW_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        switch page {
        case "log", "log-empty":
            presentLogPreview(empty: page == "log-empty")
        default:
            presentPanelPreview(page: page, environment: environment)
        }
        return true
    }

    // MARK: - 面板

    private static func presentPanelPreview(page: String, environment: [String: String]) {
        let model = makeModel(page: page, environment: environment)
        applyRoute(page, to: model)

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight)
        hosting.layoutSubtreeIfNeeded()

        // 首层取内容自然高度；二级页本身就锁到最大高
        print("CLASH_PREVIEW_FIT \(Int(hosting.fittingSize.height)) groups=\(model.groups.count) subs=\(model.subscriptions.count) load=\(model.subscriptionPanelState)")
        let isRoot = (model.route == .root)
        let height = isRoot
            ? min(max(hosting.fittingSize.height, 240), Metrics.panelHeight)
            : Metrics.panelHeight

        present(
            hosting,
            size: NSSize(width: Metrics.panelWidth, height: height),
            name: "panel-\(page)"
        )
    }

    private static func makeModel(page: String, environment: [String: String]) -> PanelPreviewModel {
        switch page {
        case "root-empty":
            // 指向空目录：没有激活订阅，走「还没有配置」空态
            let directory = URL.temporaryDirectory.appending(
                path: "clash-preview-empty-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return PanelPreviewModel(
                profileStore: ProfileStore(directory: directory),
                systemProxy: SystemProxyService(
                    snapshotURL: directory.appending(path: "systemproxy-snapshot.json")
                ),
                autoStartsKernel: false
            )

        case "subscriptions-loading":
            // loadsImmediately: false → 永远停在「正在读取订阅…」
            return PanelPreviewModel(
                profileStore: ProfileStore(
                    directory: URL.temporaryDirectory.appending(path: "clash-preview-loading"),
                    loadsImmediately: false
                ),
                systemProxy: SystemProxyService(
                    snapshotURL: URL.temporaryDirectory.appending(path: "clash-preview-snapshot.json")
                ),
                autoStartsKernel: false
            )

        case "subscriptions-failed":
            // 损坏的 index.json → 读取失败态（带原文与重试）
            let directory = URL.temporaryDirectory.appending(
                path: "clash-preview-broken-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data("{ broken".utf8).write(to: directory.appending(path: "index.json"))
            return PanelPreviewModel(
                profileStore: ProfileStore(directory: directory),
                systemProxy: SystemProxyService(
                    snapshotURL: directory.appending(path: "systemproxy-snapshot.json")
                ),
                autoStartsKernel: false
            )

        case "subscriptions-empty":
            let directory = URL.temporaryDirectory.appending(
                path: "clash-preview-no-subs-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return PanelPreviewModel(
                profileStore: ProfileStore(directory: directory),
                systemProxy: SystemProxyService(
                    snapshotURL: directory.appending(path: "systemproxy-snapshot.json")
                ),
                autoStartsKernel: false
            )

        default:
            let model = PanelPreviewModel(autoStartsKernel: false)
            model.applyPreviewGroups()
            if page == "connections" {
                model.applyPreviewConnections()
            }
            if page == "root-failed" {
                model.previewFailure()
            }
            if environment["CLASH_PREVIEW_PINNED"] != "0", page != "root-single" {
                model.pinAllPreviewGroups()
            }
            return model
        }
    }

    private static func applyRoute(_ page: String, to model: PanelPreviewModel) {
        switch page {
        case "nodes":
            if let group = model.groups.first {
                model.route = .nodes(group.id)
            }
        case "groups":
            model.route = .allGroups
        case "subscriptions", "subscriptions-empty", "subscriptions-loading", "subscriptions-failed":
            model.route = .subscriptions
        case "subscription-new":
            model.route = .subscriptionNew
        case "connections":
            model.route = .connections
        case "settings":
            model.route = .settings
        default:
            break
        }
    }

    // MARK: - 日志窗口

    private static func presentLogPreview(empty: Bool) {
        let model = PanelPreviewModel(autoStartsKernel: false)
        if !empty {
            for (index, payload) in LogPreviewFixture.lines.enumerated() {
                model.logStore.appendForSelfCheck(
                    level: LogPreviewFixture.levels[index],
                    payload: payload,
                    secret: nil
                )
            }
        }

        let hosting = NSHostingView(rootView: LogWindowView(store: model.logStore))
        present(hosting, size: NSSize(width: 760, height: 520), name: "log", titled: true)
    }

    // MARK: - 摆窗与坐标

    private static func present(_ view: NSView, size: NSSize, name: String, titled: Bool = false) {
        let window: NSWindow
        if titled {
            // 日志是独立系统窗口：要带标题栏与窗口底色，才能看到真实的窗口观感
            let titledWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            titledWindow.title = "日志"
            titledWindow.isReleasedWhenClosed = false
            window = titledWindow
        } else {
            let panel = PreviewPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            window = panel
        }
        window.contentView = view

        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if titled { window.setContentSize(size) }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visible.minX + screenInset,
            y: visible.maxY - screenInset - frame.height
        ))
        window.orderFrontRegardless()
        windows.append(window)

        // 让 App 回到「非活动」：截图里不会出现系统给首个可聚焦控件画的焦点环。
        // 面板材质 `state = .active`，配色不随窗口激活状态变化。
        NSApp.deactivate()

        let screenHeight = screen?.frame.height ?? visible.height
        let windowFrame = window.frame
        let regionX = Int(windowFrame.minX.rounded())
        let regionY = Int((screenHeight - windowFrame.maxY).rounded())
        print("CLASH_PREVIEW_REGION \(regionX),\(regionY),\(Int(windowFrame.width)),\(Int(windowFrame.height))")
        print("CLASH_PREVIEW_NAME \(name)")
        fflush(stdout)
    }
}

/// 悬浮夹具窗口：不抢 key，截图里不会出现焦点环
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 日志预览的固定内容：覆盖 info / warning / error 与长行换行
@MainActor
private enum LogPreviewFixture {
    static let lines: [String] = [
        "Start initial configuration in progress",
        "GeoSite loaded: geosite.dat, 2.1s",
        "Rule matched: DomainSuffix(apple.com) → DIRECT",
        "TCP connection to 17.253.144.10:443 opened by Safari",
        "UDP connection to 8.8.8.8:53 opened by mDNSResponder",
        "Proxy [香港 01] connected to example.com:443, latency 32ms",
        "TUN: inbound packet 10.0.0.2:51234 → 1.1.1.1:443",
        "DNS query cdn.example.net resolved to 104.18.32.7 in 12ms",
        "Warning: failed to load proxy provider \"backup\", using cached file",
        "Proxy [日本 02] connection closed, upload 12.4 KB, download 328.6 KB",
        "Error: authentication failed for proxy group \"自动选择\"",
        "Start initial configuration in progress (reload)",
    ]

    static let levels: [LogLine.Level] = [
        .info, .info, .info, .info, .info, .info,
        .info, .info, .warning, .info, .error, .info,
    ]
}
#endif
