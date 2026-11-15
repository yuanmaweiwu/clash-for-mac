import Foundation

/// mihomo RESTful API 的唯一出口（`core-process` §5）。
///
/// 其他模块禁止直接 `URLSession`。端口 / secret 变更后必须新建实例，不复用旧连接。
actor ClashAPIClient {

    enum APIError: Error, Equatable, Sendable {
        /// 连不上（进程未就绪 / 已退出 / 超时）
        case unreachable
        /// Bearer 不对
        case unauthorized
        /// 其它非 2xx
        case httpStatus(Int)
        /// 响应不是预期的 JSON
        case malformedResponse
        /// 测速被内核拒绝（节点超时 / 组内全部超时，内核回 408 / 503 / 504）
        case delayFailed
    }

    struct VersionResponse: Decodable, Sendable {
        let version: String
        let meta: Bool?
    }

    struct ProxiesResponse: Decodable, Sendable {
        let proxies: [String: ProxyEntry]
    }

    private struct ConnectionsResponse: Decodable, Sendable {
        /// 关掉全部连接后内核会把空列表序列化成 `null`，按可选解码
        let connections: [ConnectionEntry]?
    }

    private struct RulesResponse: Decodable, Sendable {
        /// 空配置时同样是 `null`
        let rules: [RuleEntry]?
    }

    private struct DelayResponse: Decodable, Sendable {
        let delay: Int
    }

    private struct NameBody: Encodable, Sendable {
        let name: String
    }

    private struct ModeBody: Encodable, Sendable {
        let mode: String
    }

    private struct ConfigPathBody: Encodable, Sendable {
        let path: String
    }

    private struct ConfigPayloadBody: Encodable, Sendable {
        let payload: String
    }

    /// WS 流的用途：决定 `stopTraffic()` / `stopLogs()` 各关哪些 socket
    private enum StreamKind {
        case traffic
        case logs
    }

    /// 一条在连的 WS 流
    private struct ActiveStream {
        let kind: StreamKind
        let socket: URLSessionWebSocketTask
    }

    private let port: Int
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    /// WS 专用会话：REST 的 5s 资源超时会把长连接掐掉，这里单独放宽
    private let streamSession: URLSession
    /// 全部在连的 WS socket（`/traffic` 与 `/logs` 一起记账，按 `kind` 区分）。
    ///
    /// 两类流必须各自可停：日志窗口关窗只能断 `/logs`，不能连累面板流量曲线。
    private var streams: [UUID: ActiveStream] = [:]

    init(port: Int, secret: String, timeout: TimeInterval = 5) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)") ?? URL(string: "http://127.0.0.1")!
        self.secret = secret

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        // 批量测速是 8 条并发请求；默认每主机 6 条会把窗口压成 6，白等
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)

        let streamConfiguration = URLSessionConfiguration.ephemeral
        streamConfiguration.timeoutIntervalForRequest = 15
        streamConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        streamConfiguration.waitsForConnectivity = false
        streamConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.streamSession = URLSession(configuration: streamConfiguration)
    }

    /// `GET /version`：连通性判定 + 面板展示版本
    func version(timeout: TimeInterval? = nil) async throws -> VersionResponse {
        let data = try await send(["version"], method: "GET", timeout: timeout)
        guard let response = try? JSONDecoder().decode(VersionResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response
    }

    /// `GET /proxies`：全部代理与策略组，键为名字（含 `GLOBAL`）
    func proxies() async throws -> [String: ProxyEntry] {
        let data = try await send(["proxies"], method: "GET")
        guard let response = try? JSONDecoder().decode(ProxiesResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response.proxies
    }

    /// `PUT /proxies/{group}` `{"name": "<节点>"}`：切组的当前节点（组名按路径段编码）
    func selectProxy(group: String, name: String) async throws {
        let body = try JSONEncoder().encode(NameBody(name: name))
        _ = try await send(["proxies", group], method: "PUT", body: body)
    }

    /// `GET /proxies/{name}/delay`：返回毫秒；超时 / 不可用归入 `delayFailed`
    func testDelay(proxy: String, timeout: Int, url: String) async throws -> Int {
        let data = try await delayRequest(components: ["proxies", proxy, "delay"], timeout: timeout, url: url)
        guard let response = try? JSONDecoder().decode(DelayResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response.delay
    }

    /// `GET /configs`：只取模式与端口，其余字段忽略
    func configs() async throws -> ConfigSnapshot {
        let data = try await send(["configs"], method: "GET")
        guard let snapshot = try? JSONDecoder().decode(ConfigSnapshot.self, from: data) else {
            throw APIError.malformedResponse
        }
        return snapshot
    }

    /// `PATCH /configs` `{"mode": ...}`：只改运行时，不落盘
    func patchMode(_ mode: String) async throws {
        let body = try JSONEncoder().encode(ModeBody(mode: mode))
        _ = try await send(["configs"], method: "PATCH", body: body)
    }

    // MARK: - 热重载（切订阅 / 更新订阅）

    /// `PUT /configs?force=true` `{"path": "..."}`：让 mihomo 就地重读运行配置。
    ///
    /// 进程 / controller 端口 / secret / pid 都不变，只是代理内容（组 / 节点 / 规则）换新。
    /// 路径由内核进程自己读，因此 TUN 场景可以直接指向 root 目录里的那份 `runtime.yaml`。
    func reloadConfig(path: String, timeout: TimeInterval = 5) async throws {
        #if DEBUG
        try Self.injectReloadFailureIfNeeded()
        #endif
        let body = try JSONEncoder().encode(ConfigPathBody(path: path))
        _ = try await send(
            ["configs"],
            method: "PUT",
            query: [URLQueryItem(name: "force", value: "true")],
            body: body,
            timeout: timeout
        )
    }

    /// `PUT /configs?force=true` 的正文变体：`path` 不被接受（内核读不到文件 / 字段被忽略）时兜底。
    func reloadConfig(payload: String, timeout: TimeInterval = 5) async throws {
        #if DEBUG
        try Self.injectReloadFailureIfNeeded()
        #endif
        let body = try JSONEncoder().encode(ConfigPayloadBody(payload: payload))
        _ = try await send(
            ["configs"],
            method: "PUT",
            query: [URLQueryItem(name: "force", value: "true")],
            body: body,
            timeout: timeout
        )
    }

    #if DEBUG
    /// 自检夹具（`CLASH_RELOAD_FAIL=1`）：强制热重载请求失败，验证 stop→start 回退。
    /// 只在 Debug 编译，生产路径无法置位。
    private static let injectsReloadFailure =
        ProcessInfo.processInfo.environment["CLASH_RELOAD_FAIL"] == "1"

    private static func injectReloadFailureIfNeeded() throws {
        guard injectsReloadFailure else { return }
        throw APIError.httpStatus(500)
    }
    #endif

    // MARK: - 连接（`core-process` §5）

    /// `GET /connections`：活动连接快照。
    ///
    /// 内核还会带 `uploadTotal` / `downloadTotal`（内核启动以来的累计值），这里不取：
    /// 面板要的是「当前列表里这些连接的总量」，由上层按条目求和，关掉连接后立刻一致。
    func connections() async throws -> [ConnectionEntry] {
        let data = try await send(["connections"], method: "GET")
        guard let response = try? JSONDecoder().decode(ConnectionsResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response.connections ?? []
    }

    /// `DELETE /connections/{id}`：关闭单条连接
    func closeConnection(id: String) async throws {
        _ = try await send(["connections", id], method: "DELETE")
    }

    /// `DELETE /connections`：关闭全部连接
    func closeAllConnections() async throws {
        _ = try await send(["connections"], method: "DELETE")
    }

    // MARK: - 规则（`core-process` §5）

    /// `GET /rules`：按配置顺序返回全部规则
    func rules() async throws -> [RuleEntry] {
        let data = try await send(["rules"], method: "GET")
        guard let response = try? JSONDecoder().decode(RulesResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response.rules ?? []
    }

    // MARK: - 实时流（WS）：`/traffic` 与 `/logs`

    /// `/traffic`：逐秒 `{up,down}`（字节 / 秒，`core-process` §5）。
    ///
    /// 看门狗 3s：流量固定每秒一帧，长时间没帧只可能是内核被挂起或连接半开。
    func traffic(idleTimeout: Duration = .seconds(3)) -> AsyncThrowingStream<TrafficSample, Error> {
        stream(
            kind: .traffic,
            path: "traffic",
            idleTimeout: idleTimeout,
            interruption: TrafficStreamError.interrupted,
            decode: Self.decodeTraffic
        )
    }

    /// 关闭所有 `/traffic` 连接（服务停止 / 内核重启）；消费端随后从 `for await` 退出
    func stopTraffic() {
        stopStreams(of: .traffic)
    }

    /// `/logs?level=<level>`：内核日志推送（`core-process` §5）。
    ///
    /// 看门狗阈值比 `/traffic` 宽得多：日志流本身可能长时间没有一帧（内核空闲），
    /// 用 3s 会一直误杀重连；这里只兜「socket 半开、`receive()` 永不返回」的极端情况。
    func logs(level: String, idleTimeout: Duration = .seconds(600)) -> AsyncThrowingStream<LogLine, Error> {
        stream(
            kind: .logs,
            path: "logs",
            query: [URLQueryItem(name: "level", value: level)],
            idleTimeout: idleTimeout,
            interruption: LogStreamError.interrupted,
            decode: Self.decodeLog
        )
    }

    /// 关闭所有 `/logs` 连接（日志窗口关闭 / 内核停止）；消费端随后从 `for await` 退出
    func stopLogs() {
        stopStreams(of: .logs)
    }

    /// 两条 WS 流唯一的实现：建 socket、记账、看门狗、收包、清理都只写在这里。
    ///
    /// - 鉴权走 `Authorization` 头（与 REST 一致）：secret 不进 URL，也就不会落进日志 / 崩溃报告
    /// - 单帧解析失败直接跳过，不中断流
    /// - 断流判定：内核被挂起或连接半开时 `receive()` 会一直不返回，超过 `idleTimeout`
    ///   没有帧就关 socket 结束流，交给上层重连（重连节奏由各消费端决定，这里不做退避）
    /// - 取消：`stopTraffic()` / `stopLogs()` 或流被释放都会关 socket，消费端 `for await` 正常退出
    /// - 收包异常一律映射成调用方给的 `interruption`：两条流保留各自的中断类型，上层据此区分来源
    private func stream<Element>(
        kind: StreamKind,
        path: String,
        query: [URLQueryItem] = [],
        idleTimeout: Duration,
        interruption: any Error & Sendable,
        decode: @escaping @Sendable (URLSessionWebSocketTask.Message) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        let socket = streamSession.webSocketTask(with: streamRequest(path: path, query: query))
        let id = UUID()
        streams[id] = ActiveStream(kind: kind, socket: socket)

        return AsyncThrowingStream { continuation in
            let activity = FrameActivity()

            let producer = Task {
                socket.resume()

                // 看门狗：只负责「多久没帧」，收到帧的判定在收包循环里做
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard await activity.isIdle(beyond: idleTimeout) else { continue }
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
                defer { watchdog.cancel() }

                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        await activity.touch()
                        guard let element = decode(message) else { continue }
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: interruption)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                Task { await self.removeStream(id) }
            }
        }
    }

    /// 关掉某一类流并清账；另一类不受影响（关日志窗口不能连累流量曲线）
    private func stopStreams(of kind: StreamKind) {
        for id in streams.filter({ $0.value.kind == kind }).map(\.key) {
            streams.removeValue(forKey: id)?.socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func removeStream(_ id: UUID) {
        streams.removeValue(forKey: id)
    }

    private func streamRequest(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/" + path
        if !query.isEmpty {
            components.queryItems = query
        }

        var request = URLRequest(url: components.url ?? URL(string: "ws://127.0.0.1")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func decodeTraffic(_ message: URLSessionWebSocketTask.Message) -> TrafficSample? {
        guard let data = payloadData(of: message) else { return nil }
        return try? JSONDecoder().decode(TrafficSample.self, from: data)
    }

    private static func decodeLog(_ message: URLSessionWebSocketTask.Message) -> LogLine? {
        guard let data = payloadData(of: message) else { return nil }
        return LogLine(wire: data)
    }

    private static func payloadData(of message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let payload):
            return payload
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return nil
        }
    }

    // MARK: - 请求

    /// 测速：`timeout` 是内核侧探测超时（毫秒），HTTP 超时按 §5 再加 2s
    private func delayRequest(components: [String], timeout: Int, url: String) async throws -> Data {
        let query = [
            URLQueryItem(name: "timeout", value: String(timeout)),
            URLQueryItem(name: "url", value: url)
        ]
        do {
            return try await send(
                components,
                method: "GET",
                query: query,
                timeout: Double(timeout) / 1000 + 2
            )
        } catch APIError.httpStatus(let code) where code == 408 || code == 503 || code == 504 {
            throw APIError.delayFailed
        }
    }

    @discardableResult
    private func send(
        _ components: [String],
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var url = baseURL
        for component in components {
            url = url.appending(path: component)
        }
        if !query.isEmpty {
            url = url.appending(queryItems: query)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let timeout {
            request.timeoutInterval = timeout
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 取消不是「内核未响应」：测速要把取消与超时分开（取消不写缓存）
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw APIError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw APIError.unauthorized
        default:
            throw APIError.httpStatus(http.statusCode)
        }
    }
}

extension ClashAPIClient.APIError {
    /// 面向用户的中文文案（`core-process` §7：新错误都要有中文文案）
    var userMessage: String {
        switch self {
        case .unreachable:
            "内核未响应"
        case .unauthorized:
            "内核鉴权失败，请重启内核"
        case .httpStatus(let code):
            "内核返回错误（\(code)）"
        case .malformedResponse:
            "内核返回了无法识别的数据"
        case .delayFailed:
            "测速失败，请稍后重试"
        }
    }
}

/// `/traffic` 流的中断原因：握手失败、socket 被关、或断流（长时间无帧）。
enum TrafficStreamError: Error, Equatable, Sendable {
    case interrupted
}

/// `/logs` 流的中断原因（同上）
enum LogStreamError: Error, Equatable, Sendable {
    case interrupted
}

/// 最近一帧的到达时间；看门狗与收包循环跨 actor 共享。
private actor FrameActivity {
    private var last = ContinuousClock.now

    func touch() {
        last = ContinuousClock.now
    }

    func isIdle(beyond duration: Duration) -> Bool {
        ContinuousClock.now - last > duration
    }
}

