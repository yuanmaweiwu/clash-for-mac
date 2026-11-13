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

    private struct DelayResponse: Decodable, Sendable {
        let delay: Int
    }

    private struct NameBody: Encodable, Sendable {
        let name: String
    }

    private struct ModeBody: Encodable, Sendable {
        let mode: String
    }

    private let baseURL: URL
    private let secret: String
    private let session: URLSession

    init(port: Int, secret: String, timeout: TimeInterval = 5) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)") ?? URL(string: "http://127.0.0.1")!
        self.secret = secret

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
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
