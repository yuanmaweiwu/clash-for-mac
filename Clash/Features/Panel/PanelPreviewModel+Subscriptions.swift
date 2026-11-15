import Foundation

// 订阅库：View 用的同名转发入口 + `SubscriptionActionsHost` 实现。
// 真正的写操作与内核重启编排在 `SubscriptionActions`。

extension PanelPreviewModel {

    func activateSubscription(_ id: String) { actions.activate(id) }

    func updateSubscription(_ id: String) { actions.update(id) }

    func renameSubscription(_ id: String, to newName: String) { actions.rename(id, to: newName) }

    func deleteSubscription(_ id: String) { actions.delete(id) }

    func importSubscription(urlString: String) { actions.importURL(urlString) }

    func importLocalSubscription(fileURL: URL) { actions.importFile(at: fileURL) }
}

// MARK: - SubscriptionActionsHost

extension PanelPreviewModel: SubscriptionActionsHost {

    func subscriptionActionsProxyTurnedOff() {
        connectionState = .off
    }

    func subscriptionActionsProxyFailed(_ error: Error) {
        failConnection(.disable, error: error)
    }

    func subscriptionActionsProfilesCleared() {
        proxies.clear()
        pruneRouteIfTargetMissing()
    }

    func subscriptionActionsDidReloadProxies() {
        // TUN 热重载不重启内核，相位一直是 `.on`，`onPhaseChange` 不会触发；
        // 这里主动刷新一次，和内核重启路径的「running → refresh」保持同一语义。
        Task { [weak self] in
            guard let self else { return }
            guard await self.proxies.refresh() else { return }
            self.pruneRouteIfTargetMissing()
        }
    }

    func subscriptionActionsDidImport() {
        if route == .subscriptionNew { route = .subscriptions }
    }

    func subscriptionActionsImportFailed(_ message: String) {
        // 添加页内用红字（`actions.importError`）；从列表页发起时才补一条 3s 提示
        if route != .subscriptionNew { actions.showNotice(message) }
    }
}
