import Foundation
import Observation

/// 节点测速的编排：批量测速 Task、结果提示（2.5s）、完成闪烁（1.5s）。
///
/// 只依赖 `ProxyService`（真正的 `/group/{name}/delay` 与互斥都在它里面），
/// 不反向依赖 `PanelPreviewModel`；面板只做同名转发，View 不需要改。
@MainActor
@Observable
final class SpeedTestController {

    /// 「没有可测速的节点」/ 测速失败文案（2.5s 自动消失）
    private(set) var notice: String?
    /// 测速完成后的「刚刚更新」短暂提示
    private(set) var resultFlash = false

    @ObservationIgnored private let proxies: ProxyService
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    init(proxies: ProxyService) {
        self.proxies = proxies
    }

    /// 该组是否正在测速（标题行按钮据此换 ProgressView 并禁用）
    func isTesting(_ groupID: String) -> Bool { proxies.testingGroup == groupID }

    /// 批量测速。`hasNodes` 由调用方从策略组快照判断，避免这里再持有一份组数据。
    ///
    /// 再次触发会先取消上一次：`ProxyService.testAll` 自身也有互斥，这里只保证
    /// 「用户连点两次时不留下两条结果提示」。
    func testAll(in groupID: String, hasNodes: Bool) {
        guard proxies.testingGroup == nil else { return }
        guard hasNodes else {
            showNotice("没有可测速的节点")
            return
        }

        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.proxies.testAll(group: groupID)
            guard !Task.isCancelled else { return }

            if let error = self.proxies.lastError {
                self.showNotice(error)
            } else {
                self.flashResult()
            }
        }
    }

    private func flashResult() {
        resultFlash = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.resultFlash = false
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }
}
