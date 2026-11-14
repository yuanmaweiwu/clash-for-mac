#if DEBUG
import Foundation

// Preview 夹具（仅 DEBUG）：不启动内核 / 不联网，摆出固定状态供设计预览。
extension PanelPreviewModel {

    /// Preview 夹具：直接摆出启动失败态（不启动内核）
    func previewFailure() {
        kernel.applyPreviewFailure()
    }

    /// Preview 夹具：不启动内核，摆出四种网络检测状态（不发真实请求）
    func applyPreviewNetworkProbes() {
        networkProbes.applyPreviewStates()
    }

    /// Preview 夹具：摆出几条典型规则（不请求内核）
    func applyPreviewRules() {
        ruleService.applyPreviewRules()
    }

    /// Preview 夹具：不启动内核，摆出策略组（仅设计预览用）
    func applyPreviewGroups() {
        proxies.applyPreviewFixture()
    }

    /// Preview 夹具：摆出几张活动连接（不请求内核）
    func applyPreviewConnections() {
        connections.applyPreviewConnections()
    }
}
#endif
