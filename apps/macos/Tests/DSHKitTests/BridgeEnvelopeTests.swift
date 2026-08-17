import Testing
import Foundation
@testable import DSHKit

@Suite("控制通道信封（bridge-contract.md §1.2）")
struct BridgeEnvelopeTests {
    @Test("四态编解码 round trip")
    func roundTripsAllFourKinds() throws {
        let identifier = MessageID("01J000000000000000000000AB")
        let envelopes: [BridgeEnvelope] = [
            .request(id: identifier, method: "slot/invoke", payload: .object(["action": .string("startSession")])),
            .success(id: identifier, payload: .object(["applied": .array([.string("sidebar.workspaces")])])),
            .failure(id: identifier, error: BridgeFault(code: .slotNotMounted, message: "gone", retryable: false)),
            .event(method: "slot/rect", payload: .object(["scrollable": .bool(false)])),
        ]
        for envelope in envelopes {
            let text = try envelope.jsonText()
            let decoded = try BridgeEnvelope.decode(json: text)
            #expect(decoded == envelope)
        }
        #expect(envelopes.map(\.kind) == [.req, .res, .err, .evt])
    }

    @Test("线上编码遵守 v/t/id/m/p/e/ok 字段名")
    func wireShapeMatchesContract() throws {
        let request = BridgeEnvelope.request(
            id: MessageID("01J000000000000000000000AB"),
            method: "surface/configure",
            payload: .object(["manifest": .object([:])])
        )
        let value = request.encoded()
        #expect(value["v"]?.intValue == 1)
        #expect(value["t"]?.stringValue == "req")
        #expect(value["id"]?.stringValue == "01J000000000000000000000AB")
        #expect(value["m"]?.stringValue == "surface/configure")
        #expect(value["p"] != nil)

        let failure = BridgeEnvelope.failure(
            id: MessageID("01J000000000000000000000AB"),
            error: BridgeFault(code: .priorityConflict, message: "ui-workspace owns it")
        )
        let failureValue = failure.encoded()
        #expect(failureValue["t"]?.stringValue == "res")
        #expect(failureValue["ok"]?.boolValue == false)
        #expect(failureValue["e"]?["code"]?.stringValue == "priority_conflict")
    }

    @Test("未知协议版本被拒绝，不猜")
    func rejectsUnknownProtocolVersion() throws {
        let text = #"{"v":2,"t":"evt","m":"surface/ready","p":{}}"#
        #expect(throws: BridgeDecodingError.unsupportedProtocolVersion(2)) {
            try BridgeEnvelope.decode(json: text)
        }
    }

    @Test("缺 v / v 不是整数也被拒绝")
    func rejectsMalformedVersion() throws {
        #expect(throws: BridgeDecodingError.malformedProtocolVersion) {
            try BridgeEnvelope.decode(json: #"{"t":"evt","m":"slot/mount"}"#)
        }
        #expect(throws: BridgeDecodingError.malformedProtocolVersion) {
            try BridgeEnvelope.decode(json: #"{"v":"1","t":"evt","m":"slot/mount"}"#)
        }
    }

    @Test("未知 t 被拒绝")
    func rejectsUnknownKind() throws {
        #expect(throws: BridgeDecodingError.unknownMessageKind("push")) {
            try BridgeEnvelope.decode(json: #"{"v":1,"t":"push","m":"slot/mount"}"#)
        }
    }

    @Test("错误码是封闭集合：未知码被拒绝")
    func rejectsUnknownErrorCode() throws {
        let text = #"{"v":1,"t":"res","id":"01J0","ok":false,"e":{"code":"teapot","message":"nope"}}"#
        #expect(throws: BridgeDecodingError.unknownErrorCode("teapot")) {
            try BridgeEnvelope.decode(json: text)
        }
        // 封闭集合的内容也钉住：加码要改契约文档，不能顺手加。
        #expect(Set(BridgeErrorCode.allCases.map(\.rawValue)) == [
            "unknown_method", "bad_payload", "protocol_mismatch",
            "slot_not_declared", "slot_not_mounted", "priority_conflict", "internal",
        ])
        #expect(BridgeErrorCode.priorityConflict.demandsHumanDecision)
        #expect(!BridgeErrorCode.badPayload.demandsHumanDecision)
    }

    @Test("res 缺 ok / err 缺 e 都被拒绝")
    func rejectsIncompleteResponses() throws {
        #expect(throws: (any Error).self) {
            try BridgeEnvelope.decode(json: #"{"v":1,"t":"res","id":"01J0","p":{}}"#)
        }
        #expect(throws: (any Error).self) {
            try BridgeEnvelope.decode(json: #"{"v":1,"t":"res","id":"01J0","ok":false}"#)
        }
    }

    @Test("超长 id 被拒绝（不可信输入）")
    func rejectsOversizedID() throws {
        let long = String(repeating: "A", count: 500)
        #expect(throws: (any Error).self) {
            try BridgeEnvelope.decode(json: #"{"v":1,"t":"req","id":"\#(long)","m":"slot/probe"}"#)
        }
    }

    @Test("超时表：req 5s，surface/configure 15s")
    func timeoutTable() {
        #expect(ControlMethod.timeout(for: ControlMethod.slotInvoke) == .seconds(5))
        #expect(ControlMethod.timeout(for: ControlMethod.surfaceConfigure) == .seconds(15))
        #expect(ControlMethod.timeout(for: ControlMethod.surfaceReconfigure) == .seconds(5))
    }

    @Test("ULID 是 26 位 Crockford base32 且单调")
    func ulidIsWellFormedAndMonotonic() {
        let first = ULID.generate()
        let second = ULID.generate()
        #expect(first.isWellFormed)
        #expect(second.isWellFormed)
        #expect(first.rawValue.count == 26)
        // 同毫秒内也必须严格单调：否则并发的两个 req 会撞 id、回执错配。
        #expect(second.rawValue > first.rawValue)
    }
}
