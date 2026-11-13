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
    }

    struct VersionResponse: Decodable, Sendable {
        let version: String
        let meta: Bool?
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
        let data = try await get("version", timeout: timeout)
        guard let response = try? JSONDecoder().decode(VersionResponse.self, from: data) else {
            throw APIError.malformedResponse
        }
        return response
    }

    private func get(_ path: String, timeout: TimeInterval?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
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
