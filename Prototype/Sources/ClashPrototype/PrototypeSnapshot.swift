import AppKit
import SwiftUI

/// `--snapshot <目录>`：把几种状态离屏渲染成 PNG，供评审或自查用。
/// 只服务于原型，不进入正常启动路径。
@MainActor
enum PrototypeSnapshot {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot"),
              arguments.index(after: flagIndex) < arguments.endIndex else {
            return false
        }

        let directory = URL(fileURLWithPath: arguments[arguments.index(after: flagIndex)], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let single = PrototypeModel()

        let pinned = PrototypeModel()
        pinned.pinAllGroups()

        let dark = PrototypeModel()
        dark.appearance = .dark
        dark.wallpaper = .dark
        dark.pinAllGroups()

        let failed = PrototypeModel()
        failed.pinAllGroups()
        failed.enterFailedState()

        let empty = PrototypeModel()
        empty.enterIdleState()
        empty.showsEmptyState = true

        let nodes = PrototypeModel()
        if let group = nodes.groups.first {
            nodes.route = .nodes(group.id)
        }

        let nodesSorted = PrototypeModel()
        if let group = nodesSorted.groups.first {
            nodesSorted.route = .nodes(group.id)
            // 夹具：测速完成后的固定结果（香港 01 变慢，首行换成台湾 05）
            nodesSorted.applySpeedTestFixture(
                groupID: group.id,
                latencies: ["香港 01": 96, "台湾 05": 41, "新加坡 04": 64, "日本 02": 88, "韩国 06": 95]
            )
        }

        let nodesTesting = PrototypeModel()
        if let group = nodesTesting.groups.first {
            nodesTesting.route = .nodes(group.id)
            nodesTesting.enterSpeedTestingState(groupID: group.id)
        }

        let subscriptions = PrototypeModel()
        subscriptions.route = .subscriptions

        // 首行 hover：首行恒为选中项，用来核胶囊与卡顶的 2pt 留白
        let hoverFirst = PrototypeModel()
        hoverFirst.pinAllGroups()
        hoverFirst.debugHoverRowIndex = 0
        hoverFirst.debugHoverCardIndex = 0

        // 相邻 hover：第二行 hover（灰），核对与上一行胶囊的间隔
        let hoverAdjacent = PrototypeModel()
        hoverAdjacent.pinAllGroups()
        hoverAdjacent.debugHoverRowIndex = 1
        hoverAdjacent.debugHoverCardIndex = 0

        // 切到「新加坡 04」后，它必须置顶
        let selectedTop = PrototypeModel()
        if let group = selectedTop.groups.first,
           let node = group.nodes.first(where: { $0.name == "新加坡 04" }) {
            selectedTop.selectNode(groupID: group.id, nodeID: node.id)
        }

        // 末行 hover：用第二张卡（新加坡 04 可用），看卡片底边留白
        let hoverLast = PrototypeModel()
        hoverLast.pinAllGroups()
        hoverLast.debugHoverRowIndex = 2
        hoverLast.debugHoverCardIndex = 1

        let allGroups = PrototypeModel()
        allGroups.route = .allGroups

        let hoverGroup = PrototypeModel()
        hoverGroup.route = .allGroups
        hoverGroup.debugHoverGroupIndex = 1

        let hoverSubscription = PrototypeModel()
        hoverSubscription.route = .subscriptions
        hoverSubscription.debugHoverSubscriptionIndex = 1

        let hoverDark = PrototypeModel()
        hoverDark.appearance = .dark
        hoverDark.wallpaper = .dark
        hoverDark.pinAllGroups()
        if let group = hoverDark.groups.first, group.nodes.count > 1 {
            hoverDark.selectNode(groupID: group.id, nodeID: group.nodes[1].id)
        }
        hoverDark.debugHoverRowIndex = 0
        hoverDark.debugHoverCardIndex = 0

        let hoverHeader = PrototypeModel()
        hoverHeader.pinAllGroups()
        hoverHeader.debugHoverHeader = true
        hoverHeader.debugHoverCardIndex = 0

        render(
            PrototypeRootView(model: single),
            size: CGSize(width: Metrics.windowWidth, height: Metrics.windowHeight),
            appearance: .aqua,
            to: directory.appendingPathComponent("window-light.png")
        )
        render(
            PrototypeRootView(model: dark),
            size: CGSize(width: Metrics.windowWidth, height: Metrics.windowHeight),
            appearance: .darkAqua,
            to: directory.appendingPathComponent("window-dark.png")
        )

        renderPanel(single, name: "panel-single@2x.png", appearance: .aqua, in: directory)
        renderPanel(pinned, name: "panel-pinned@2x.png", appearance: .aqua, in: directory)
        renderPanel(dark, name: "panel-dark@2x.png", appearance: .darkAqua, in: directory)
        renderPanel(failed, name: "panel-failed@2x.png", appearance: .aqua, in: directory)
        renderPanel(empty, name: "panel-empty@2x.png", appearance: .aqua, in: directory)
        renderPanel(nodes, name: "panel-nodes@2x.png", appearance: .aqua, in: directory)
        renderPanel(nodesTesting, name: "panel-nodes-testing@2x.png", appearance: .aqua, in: directory)
        renderPanel(nodesSorted, name: "panel-nodes-sorted@2x.png", appearance: .aqua, in: directory)
        render(
            PanelView(model: single),
            size: CGSize(width: Metrics.panelWidth, height: single.panelHeight),
            appearance: .aqua,
            scale: 5,
            to: directory.appendingPathComponent("panel-single@5x.png")
        )
        renderPanel(subscriptions, name: "panel-subscriptions@2x.png", appearance: .aqua, in: directory)
        renderPanel(allGroups, name: "panel-groups@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverGroup, name: "hover-group-row@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverSubscription, name: "hover-subscription-row@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverFirst, name: "hover-first-row@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverAdjacent, name: "hover-adjacent-row@2x.png", appearance: .aqua, in: directory)
        renderPanel(selectedTop, name: "panel-selected-top@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverLast, name: "hover-last-row@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverHeader, name: "hover-header@2x.png", appearance: .aqua, in: directory)
        renderPanel(hoverDark, name: "hover-dark@2x.png", appearance: .darkAqua, in: directory)

        return true
    }

    private static func renderPanel(
        _ model: PrototypeModel,
        name: String,
        appearance: NSAppearance.Name,
        in directory: URL
    ) {
        render(
            PanelView(model: model),
            size: CGSize(width: Metrics.panelWidth, height: model.displayedPanelHeight),
            appearance: appearance,
            scale: 2,
            to: directory.appendingPathComponent(name)
        )
    }

    private static func render(
        _ view: some View,
        size: CGSize,
        appearance: NSAppearance.Name,
        scale: Int = 1,
        to url: URL
    ) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size

        host.cacheDisplay(in: host.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
