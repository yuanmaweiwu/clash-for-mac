import Foundation

/// `--selftest`：不开窗口，直接驱动状态机并打印结果，验证过渡 / 回滚 / 二级面板。
@MainActor
enum PrototypeSelfTest {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--selftest") else { return false }
        setvbuf(stdout, nil, _IONBF, 0)

        Task { @MainActor in
            let model = PrototypeModel()

            model.phase = .stopped
            model.systemProxyOn = false
            print("1. 初始：\(model.status.title)")

            model.toggleConnection()
            print("2. 点连接：\(model.status.title)")
            try? await Task.sleep(for: .seconds(1.0))
            print("3. 0.9s 后：\(model.status.title)")

            model.toggleConnection()
            print("4. 再点连接（关系统代理）：\(model.status.title)")

            model.simulateFailure = true
            model.phase = .stopped
            model.toggleConnection()
            try? await Task.sleep(for: .seconds(1.7))
            print("5. 模拟失败 1.7s 后：\(model.status.title)")

            model.toggleTun()
            model.toggleTun()
            print("6. 点 TUN：\(model.tun.rawValue)")
            try? await Task.sleep(for: .seconds(1.4))
            print("7. 1.4s 后 TUN：\(model.tun.rawValue)")

            model.simulateFailure = false
            model.phase = .running
            model.systemProxyOn = true
            model.selectMode(.direct)
            print("8. 切直连：\(model.status.title)")
            model.selectMode(.rule)
            print("9. 回规则：\(model.status.title)")

            if let group = model.groups.first {
                model.pushGroup(group.id)
                print("10. 推入二级：\(model.pushedGroup?.name ?? "无")")
                model.popToRoot()
                print("11. 返回：\(model.route)")
            }

            model.togglePin(model.groups[1].id)
            print("12. pin 自动选择：\(model.pinnedGroups.map(\.name)) / 面板高 \(Int(model.panelHeight))")
            model.popToRoot()
            model.route = .subscriptions
            if let active = model.activeSubscription {
                print("13. 订阅面板，激活：\(active.name)")
            }
            if let second = model.subscriptions.first(where: { $0.id != model.activeSubscriptionID }) {
                model.activateSubscription(second.id)
                print("14. 切换激活：\(model.activeSubscription?.name ?? "无")")
                model.updateSubscription(second.id)
                try? await Task.sleep(for: .seconds(1.5))
                print("15. 更新失败态：\(model.subscriptions.first { $0.id == second.id }?.updateFailed ?? false)")
                model.deleteSubscription(second.id)
                print("16. 删除后：\(model.activeSubscription?.name ?? "无") / 提示 \(model.subscriptionNotice ?? "无")")
            }

            exit(0)
        }

        return true
    }
}
