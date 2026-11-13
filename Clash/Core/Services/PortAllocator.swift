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

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sockaddrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, sockaddrSize) }
        }
        guard bindResult == 0 else {
            throw Failure.bindFailed(code: errno)
        }

        var bound = sockaddr_in()
        var boundSize = sockaddrSize
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
}
