import Testing
import Foundation
@testable import DSHKit
@testable import DSHClient

@Suite("SSE 解析（text/event-stream）")
struct SSEParserTests {
    private func messages(_ text: String) -> [SSEMessage] {
        var parser = SSEParser()
        return parser.consume(Data(text.utf8))
    }

    @Test("id / event / data 三字段")
    func parsesBasicMessage() {
        let parsed = messages("id: 128\nevent: session\ndata: {\"a\":1}\n\n")
        #expect(parsed.count == 1)
        #expect(parsed[0].id == "128")
        #expect(parsed[0].event == "session")
        #expect(parsed[0].data == #"{"a":1}"#)
    }

    @Test("多行 data 用 \\n 连接（SSE 规范）")
    func joinsMultilineData() {
        let parsed = messages("data: {\ndata: \"a\":1}\n\n")
        #expect(parsed[0].data == "{\n\"a\":1}")
    }

    @Test("注释行 / keep-alive 不产生消息")
    func ignoresComments() {
        #expect(messages(": ping\n\n").isEmpty)
        #expect(messages("\n\n\n").isEmpty)
    }

    @Test("CRLF 与分片到达都能正确切分")
    func handlesCRLFAndSplitChunks() {
        var parser = SSEParser()
        #expect(parser.consume(Data("id: 7\r\nevent: host\r\nda".utf8)).isEmpty)
        let parsed = parser.consume(Data("ta: {\"type\":\"host/x\"}\r\n\r\n".utf8))
        #expect(parsed.count == 1)
        #expect(parsed[0].id == "7")
        #expect(parsed[0].event == "host")
        #expect(parsed[0].data == #"{"type":"host/x"}"#)
    }

    @Test("id 在下一条消息里保持（SSE 规范：id 是粘性的）")
    func idIsSticky() {
        var parser = SSEParser()
        let first = parser.consume(Data("id: 10\ndata: a\n\ndata: b\n\n".utf8))
        #expect(first.count == 2)
        #expect(first[0].id == "10")
        #expect(first[1].id == "10")
        #expect(first[1].event == nil) // event 不粘
    }

    @Test("retry 与未知字段")
    func parsesRetryAndIgnoresUnknownFields() {
        let parsed = messages("retry: 3000\nnonsense: x\ndata: a\n\n")
        #expect(parsed[0].retry == 3000)
    }
}

@Suite("续传策略（bridge-contract.md §2.3）")
struct ResumePolicyTests {
    @Test("有游标且断得不久 → 带 Last-Event-ID 续传")
    func resumesWithinWindow() {
        let policy = ResumePolicy(retentionWindow: 120)
        #expect(policy.plan(lastEventID: "128", disconnectedFor: 30) == .resume(lastEventID: "128"))
    }

    @Test("首次连接 / 断太久 → 放弃增量，重拉快照")
    func fullResyncOutsideWindow() {
        let policy = ResumePolicy(retentionWindow: 120)
        #expect(policy.plan(lastEventID: nil, disconnectedFor: 0) == .fullResync)
        #expect(policy.plan(lastEventID: "", disconnectedFor: 0) == .fullResync)
        #expect(policy.plan(lastEventID: "128", disconnectedFor: 121) == .fullResync)
        #expect(policy.plan(lastEventID: "128", disconnectedFor: .infinity) == .fullResync)
    }

    @Test("退避有上限")
    func backoffIsBounded() {
        let policy = ResumePolicy(minimumBackoff: 0.5, maximumBackoff: 10)
        #expect(policy.backoff(attempt: 1) == 0.5)
        #expect(policy.backoff(attempt: 2) == 1)
        #expect(policy.backoff(attempt: 5) == 8)
        #expect(policy.backoff(attempt: 50) == 10)
    }

    @Test("换 token / 修权限之前重试没有意义")
    func retryability() {
        #expect(DisconnectReason.unauthorized.isRetryable == false)
        #expect(DisconnectReason.insecureDescriptor("x").isRetryable == false)
        #expect(DisconnectReason.streamEnded.isRetryable)
        #expect(DisconnectReason.runtimeNotRunning("/x").isRetryable)
    }

    @Test("失联横幅文案对每种原因都有（断连必须可见）")
    func bannerCoversEveryReason() {
        #expect(RuntimeLinkState.live(since: Date()).bannerText == nil)
        #expect(RuntimeLinkState.connecting.bannerText != nil)
        #expect(RuntimeLinkState.resyncing.bannerText != nil)
        for reason: DisconnectReason in [
            .runtimeNotRunning("/x"), .unauthorized, .insecureDescriptor("x"),
            .transport("x"), .streamEnded,
        ] {
            #expect(RuntimeLinkState.disconnected(reason: reason, since: Date()).bannerText != nil)
        }
    }
}

@Suite("bridge.json 读取与安全校验（bridge-contract.md §2.1 / §5）")
struct BridgeDescriptorTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-studio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ json: String, to directory: URL, permissions: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent("bridge.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url
    }

    @Test("$DSH_HOME/studio/bridge.json 的路径解析")
    func resolvesPath() {
        #expect(DSHHome.bridgeDescriptorURL(environment: ["DSH_HOME": "/tmp/dsh"]).path == "/tmp/dsh/studio/bridge.json")
        #expect(DSHHome.bridgeDescriptorURL(environment: ["HOME": "/Users/me"]).path == "/Users/me/.dsh/studio/bridge.json")
    }

    @Test("正常 descriptor：token + loopback + 端口")
    func loadsValidDescriptor() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"host":"127.0.0.1","port":43180,"token":"t0ken","protocol":1,"webUrl":"http://127.0.0.1:43180/"}"#, to: directory)
            let descriptor = try BridgeDescriptorLoader(url: url).load()
            #expect(descriptor.token == "t0ken")
            #expect(descriptor.baseURL.absoluteString == "http://127.0.0.1:43180")
            #expect(descriptor.authorizationHeaders["Authorization"] == "Bearer t0ken")
            #expect(descriptor.shellURL?.absoluteString == "http://127.0.0.1:43180/")
        }
    }

    @Test("缺字段走保守默认值")
    func appliesConservativeDefaults() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"token":"t"}"#, to: directory)
            let descriptor = try BridgeDescriptorLoader(url: url).load()
            #expect(descriptor.host == "127.0.0.1")
            #expect(descriptor.port == 43180)
        }
    }

    @Test("没有 token → 拒绝连接，不做匿名请求")
    func refusesWithoutToken() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"host":"127.0.0.1","port":43180}"#, to: directory)
            #expect(throws: BridgeDescriptorError.missingToken(path: url.path)) {
                try BridgeDescriptorLoader(url: url).load()
            }
        }
    }

    @Test("非 loopback host → 硬拒绝（永不 0.0.0.0）")
    func refusesNonLoopback() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"host":"0.0.0.0","port":43180,"token":"t"}"#, to: directory)
            #expect(throws: BridgeDescriptorError.nonLoopbackHost("0.0.0.0")) {
                try BridgeDescriptorLoader(url: url).load()
            }
        }
    }

    @Test("权限比 0600 松 → 拒绝（同机进程不该能驱动 agent）")
    func refusesLoosePermissions() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"token":"t"}"#, to: directory, permissions: 0o644)
            #expect(throws: BridgeDescriptorError.insecurePermissions(path: url.path, mode: 0o644)) {
                try BridgeDescriptorLoader(url: url).load()
            }
        }
    }

    @Test("文件不存在 / 不是 JSON → 明确的失败原因")
    func reportsMissingAndMalformed() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("nope.json")
            #expect(throws: BridgeDescriptorError.notFound(path: missing.path)) {
                try BridgeDescriptorLoader(url: missing).load()
            }
            let url = try write("not json", to: directory)
            #expect(throws: (any Error).self) {
                try BridgeDescriptorLoader(url: url).load()
            }
        }
    }

    @Test("端口越界 → 拒绝")
    func refusesBadPort() throws {
        try withTemporaryDirectory { directory in
            let url = try write(#"{"token":"t","port":0}"#, to: directory)
            #expect(throws: BridgeDescriptorError.portOutOfRange(0)) {
                try BridgeDescriptorLoader(url: url).load()
            }
        }
    }
}
