import Foundation

/// 一次 HTTP 往返的结果。
public struct HTTPReply: Sendable, Hashable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// 数据通道的传输抽象。
///
/// 抽出来的唯一目的：让 `DSHClient` 的续传/重放/失联逻辑可以在**无网络、
/// 无 dsh 进程**的情况下被测试。生产实现是 `URLSessionTransport`。
public protocol DSHTransport: Sendable {
    func post(path: String, body: Data, headers: [String: String]) async throws -> HTTPReply

    /// 打开一条 SSE。返回状态码 + 按行切好的原始字节块。
    func openStream(
        path: String,
        headers: [String: String]
    ) async throws -> (status: Int, chunks: AsyncThrowingStream<Data, any Error>)
}

/// 生产实现：`URLSession` over loopback。
public final class URLSessionTransport: DSHTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // SSE 是长连接：不给它设读超时，否则每 60s 断一次。
            configuration.timeoutIntervalForRequest = 0
            configuration.timeoutIntervalForResource = 0
            self.session = URLSession(configuration: configuration)
        }
    }

    public func post(path: String, body: Data, headers: [String: String]) async throws -> HTTPReply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        return HTTPReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    public func openStream(
        path: String,
        headers: [String: String]
    ) async throws -> (status: Int, chunks: AsyncThrowingStream<Data, any Error>) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 0
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}
