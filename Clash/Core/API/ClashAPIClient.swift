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

    private struct DelayResponse: Decodable, Sendable {
        let delay: Int
    }

    private struct NameBody: Encodable, Sendable {
        let name: String
    }

    private struct ModeBody: Encodable, Sendable {
        let mode: String
    }

    private let port: Int
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    /// WS 专用会话：REST 的 5s 资源超时会把长连接掐掉，这里单独放宽
    private let streamSession: URLSession
    /// 在连的 `/traffic` socket；`stopTraffic()` 与内核重启时统一关闭
    private var sockets: [UUID: URLSessionWebSocketTask] = [:]
    /// 在连的 `/logs` socket；与 `/traffic` 分开记账，日志窗口关窗不会连累流量曲线
    private var logSockets: [UUID: URLSessionWebSocketTask] = [:]

    init(port: Int, secret: String, timeout: TimeInterval = 5) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)") ?? URL(string: "http://127.0.0.1")!
        self.secret = secret

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
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

    /// `GET /group/{name}/delay`：结果为「节点名 → 毫秒」
    func testGroupDelay(group: String, timeout: Int, url: String) async throws -> [String: Int] {
        let data = try await delayRequest(components: ["group", group, "delay"], timeout: timeout, url: url)
        guard let response = try? JSONDecoder().decode([String: Int].self, from: data) else {
            throw APIError.malformedResponse
        }
        return response
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

    // MARK: - 实时流量（WS）

    /// `/traffic`：逐秒 `{up,down}`（字节 / 秒，`core-process` §5）。
    ///
    /// - 鉴权走 `Authorization` 头（与 REST 一致）：secret 不进 URL，也就不会落进日志 / 崩溃报告
    /// - 单帧解析失败直接跳过，不中断流
    /// - 断流判定：内核被挂起或连接半开时 `receive()` 会一直不返回，超过 `idleTimeout`
    ///   没有帧就关 socket 结束流，交给上层重连
    /// - 取消：`stopTraffic()` 或流被释放都会关 socket，消费端 `for await` 正常退出
    func traffic(idleTimeout: Duration = .seconds(3)) -> AsyncThrowingStream<TrafficSample, Error> {
        let socket = streamSession.webSocketTask(with: streamRequest(path: "traffic"))
        let id = UUID()
        sockets[id] = socket

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
                        guard let sample = Self.decodeTraffic(message) else { continue }
                        continuation.yield(sample)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TrafficStreamError.interrupted)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                Task { await self.removeSocket(id) }
            }
        }
    }

    /// 关闭所有 `/traffic` 连接（服务停止 / 内核重启）；消费端随后从 `for await` 退出
    func stopTraffic() {
        for socket in sockets.values {
            socket.cancel(with: .goingAway, reason: nil)
        }
        sockets.removeAll()
    }

    private func removeSocket(_ id: UUID) {
        sockets.removeValue(forKey: id)
    }

    // MARK: - 内核日志（WS）

    /// `/logs?level=<level>`：内核日志推送（`core-process` §5）。
    ///
    /// - 鉴权走 `Authorization` 头，同 `/traffic`：secret 不进 URL
    /// - 单帧解析失败直接跳过，不中断流
    /// - 看门狗阈值比 `/traffic` 宽得多：日志流本身可能长时间没有一帧（内核空闲），
    ///   用 3s 会一直误杀重连；这里只兜「socket 半开、`receive()` 永不返回」的极端情况
    /// - 取消：`stopLogs()` 或流被释放都会关 socket，消费端 `for await` 正常退出
    func logs(level: String, idleTimeout: Duration = .seconds(600)) -> AsyncThrowingStream<LogLine, Error> {
        let socket = streamSession.webSocketTask(
            with: streamRequest(path: "logs", query: [URLQueryItem(name: "level", value: level)])
        )
        let id = UUID()
        logSockets[id] = socket

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
                        guard let line = Self.decodeLog(message) else { continue }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LogStreamError.interrupted)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                Task { await self.removeLogSocket(id) }
            }
        }
    }

    /// 关闭所有 `/logs` 连接（日志窗口关闭 / 内核停止）；消费端随后从 `for await` 退出
    func stopLogs() {
        for socket in logSockets.values {
            socket.cancel(with: .goingAway, reason: nil)
        }
        logSockets.removeAll()
    }

    private func removeLogSocket(_ id: UUID) {
        logSockets.removeValue(forKey: id)
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

