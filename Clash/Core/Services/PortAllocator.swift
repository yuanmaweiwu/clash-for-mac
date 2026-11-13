import Darwin
import Foundation

/// 取一个当前空闲的本地端口。
///
/// 做法：绑定 `127.0.0.1:0`，由内核分配端口后用 `getsockname` 读回，随即关闭。
/// 端口在「探测」与「真正启动」之间理论上可能被别的进程抢走，此时由内核
/// 退出日志判定为 `portInUse`——不静默改端口（`docs/01-ARCHITECTURE.md` §4）。
enum PortAllocator {

    enum Failure: Error, Equatable, Sendable {
        case socketUnavailable(code: Int32)
        case bindFailed(code: Int32)
        case nameLookupFailed(code: Int32)
    }

    static func allocate() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.socketUnavailable(code: errno)
        }
        defer { close(descriptor) }

        var address = loopbackAddress(port: 0)
        try bindLoopback(descriptor: descriptor, address: &address)

        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundSize)
            }
        }
        guard nameResult == 0 else {
            throw Failure.nameLookupFailed(code: errno)
        }

        return Int(UInt16(bigEndian: bound.sin_port))
    }

    /// 取 `count` 个互不相同的空闲端口；任一失败即抛错，不静默重试出重复端口。
    static func allocateDistinct(_ count: Int) throws -> [Int] {
        var ports: [Int] = []
        while ports.count < count {
            let candidate = try allocate()
            guard !ports.contains(candidate) else { continue }
            ports.append(candidate)
        }
        return ports
    }

    /// 指定端口在 `127.0.0.1` 上是否还能绑定。
    ///
    /// 启动前用它确认 `mixed-port` 空闲：否则可能出现两个内核抢同一端口（其中一个绑定
    /// 失败但进程不退，行为不可预测）。任何失败（含 socket 创建失败、端口越界）都按
    /// 「不可用」返回——宁可报 `portInUse` 也不硬起。
    ///
    /// 必须带 `SO_REUSEADDR`：mihomo（Go）的监听 socket 默认带它，能跨 `TIME_WAIT`
    /// 重绑。刚清掉孤儿时 7890 上常残留 `TIME_WAIT` / `FIN_WAIT` 连接，不带这个选项会
    /// 把「可重绑」误判成占用。它**不会**让出真正在监听的端口（那需要 `SO_REUSEPORT`），
    /// 所以仍能识别「另一个进程正在监听 7890」。
    static func isAvailable(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = loopbackAddress(port: port)
        return bindLoopbackResult(descriptor: descriptor, address: &address) == 0
    }

    // MARK: - 内部

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// 绑定失败即抛 `bindFailed`（`allocate` 用）
    private static func bindLoopback(descriptor: Int32, address: inout sockaddr_in) throws {
        let result = bindLoopbackResult(descriptor: descriptor, address: &address)
        guard result == 0 else {
            throw Failure.bindFailed(code: errno)
        }
    }

    /// 绑定失败只回传 `-1`，由调用方决定归类（`isAvailable` 用）
    private static func bindLoopbackResult(descriptor: Int32, address: inout sockaddr_in) -> Int32 {
        let sockaddrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, sockaddrSize)
            }
        }
    }
}
