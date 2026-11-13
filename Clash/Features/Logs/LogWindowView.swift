import AppKit
import SwiftUI

/// 日志窗口（独立窗口，不是二级面板）：`/logs` WS 的实时输出。
///
/// 结构：工具行 36pt（级别 chip + 暂停 / 清空 / 导出）+ 可选提示条 + 日志列表 / 空态。
/// 窗口最小 640×420，默认 760×520（`ClashApp` 里 `.defaultSize`）。
/// 只在窗口打开期间连流（`store.start()` / `stop()`），关窗即停在后台不常驻。
@MainActor
struct LogWindowView: View {
    let store: LogStore
    /// TUN 模式下内核由 root helper 持有，stdout 日志落在 root 目录（App 读不到）
    var isTunMode: Bool = false

    /// 自动跟随到底部；用户手动上滚后暂停，滚回距底 40pt 内自动恢复
    @State private var followsTail = true
    @State private var failureNotice: String?
    @State private var failureTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if store.isPaused {
                noticeRow("已暂停，新日志仍在写入缓冲")
            }
            if store.showsReconnecting {
                noticeRow("连接中断，正在重试…", showsSpinner: true)
            }
            if let failureNotice {
                noticeRow(failureNotice, isError: true)
            }
            if isTunMode {
                noticeRow("TUN 模式下内核日志在 /Library/Application Support/ClashHelper/kernel.log（需管理员权限查看）")
            }

            content
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { store.start() }
        .onDisappear {
            store.stop()
            failureTask?.cancel()
        }
    }

    // MARK: - 工具行

    private var toolbar: some View {
        HStack(spacing: Space.m) {
            ForEach(LogLine.Level.chips, id: \.self) { level in
                levelChip(level)
            }

            Spacer(minLength: 12)

            ToolbarTextButton(title: store.isPaused ? "继续" : "暂停") {
                store.setPaused(!store.isPaused)
            }
            .accessibilityHint(Text(store.isPaused ? "恢复实时显示" : "冻结显示，缓冲继续写入"))

            ToolbarTextButton(title: "清空") {
                store.clear()
            }

            ToolbarTextButton(title: "导出…") {
                presentExportPanel()
            }
            .accessibilityHint(Text("把当前显示的日志另存为文本文件"))
        }
        .padding(.horizontal, Space.xl)
        .frame(height: LogWindowMetrics.toolbarHeight)
    }

    private func levelChip(_ level: LogLine.Level) -> some View {
        let isSelected = store.levelFilter.contains(level)

        return Button {
            store.toggleLevel(level)
        } label: {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(LogLevelStyle.color(level))
                    .frame(width: 6, height: 6)

                Text(level.title)
                    .font(Typography.caption)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, Space.m)
            .frame(height: Metrics.hitTarget)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                    .fill(isSelected ? Theme.rowSelected : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(Text("\(level.title) 级别"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: - 提示条

    private func noticeRow(_ text: String, isError: Bool = false, showsSpinner: Bool = false) -> some View {
        HStack(spacing: Space.s) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isError ? Theme.error : Theme.warning)
            }

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Theme.error : Theme.warning)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: LogWindowMetrics.noticeHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 列表 / 空态

    @ViewBuilder
    private var content: some View {
        if store.visibleLines.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            logList
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(store.visibleLines) { line in
                        LogRowView(line: line)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distance < LogWindowMetrics.tailSnapDistance
            } action: { _, isAtBottom in
                followsTail = isAtBottom
            }
            .onChange(of: store.visibleLines.count) { _, _ in
                guard followsTail else { return }
                scrollToTail(proxy)
            }
            .onChange(of: store.isPaused) { _, isPaused in
                guard !isPaused, followsTail else { return }
                scrollToTail(proxy)
            }
            .onAppear {
                guard followsTail else { return }
                scrollToTail(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)

            Text("暂无日志")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)

            Text("内核运行后这里会显示输出")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        guard let last = store.visibleLines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // MARK: - 导出

    /// 选目录由 UI 层负责，写文件在 `LogStore.export(to:)`
    private func presentExportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出"
        panel.message = "选择导出目录"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            try store.export(to: directory)
        } catch {
            showFailure("导出失败")
        }
    }

    private func showFailure(_ text: String) {
        failureNotice = text
        failureTask?.cancel()
        failureTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            failureNotice = nil
        }
    }
}

/// 工具行文字按钮：`text/secondary` → hover `text/primary`，28pt 热区，无底
@MainActor
private struct ToolbarTextButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Space.m)
                .frame(height: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(Text(title))
    }
}

#if DEBUG
#Preview("日志窗口 · 空态") {
    LogWindowView(store: LogStore(kernel: KernelService()))
}
#endif
