import Foundation

/// 一条 SSE 消息。
public struct SSEMessage: Hashable, Sendable {
    /// `id:` 字段 —— 断线续传用的 `Last-Event-ID`，语义上 = `seq`
    /// （bridge-contract.md §2.3）。
    public var id: String?
    /// `event:` 字段。
    public var event: String?
    /// `data:` 字段（多行会以 `\n` 连接，符合 SSE 规范）。
    public var data: String
    /// `retry:` 字段（毫秒）。
    public var retry: Int?

    public init(id: String? = nil, event: String? = nil, data: String, retry: Int? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}

/// 纯函数式 SSE 解析器（`text/event-stream`）。
///
/// 单独抽出来是为了能拿录制流量做断言（bridge-contract.md §3 的纪律：
/// 契约测试拿真实流量断言，不拿生成代码自己对自己断言）。
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var currentID: String?
    private var currentEvent: String?
    private var currentRetry: Int?

    public init() {}

    public mutating func consume(_ chunk: Data) -> [SSEMessage] {
        buffer.append(chunk)
        var messages: [SSEMessage] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if let message = consume(line: line) {
                messages.append(message)
            }
        }
        return messages
    }

    /// 处理一行；返回值非空表示这一行（空行）触发了一次派发。
    public mutating func consume(line: String) -> SSEMessage? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // 注释 / keep-alive
        }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "id":
            // SSE 规范：含 NUL 的 id 忽略。
            if !value.contains("\0") { currentID = value }
        case "event":
            currentEvent = value
        case "data":
            dataLines.append(value)
        case "retry":
            currentRetry = Int(value)
        default:
            break // 未知字段按规范忽略
        }
        return nil
    }

    private mutating func dispatch() -> SSEMessage? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            currentEvent = nil
            currentRetry = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEMessage(
            id: currentID,
            event: currentEvent,
            data: dataLines.joined(separator: "\n"),
            retry: currentRetry
        )
    }
}
