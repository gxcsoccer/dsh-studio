import Testing
import Foundation
import SwiftUI
@testable import DSHKit
@testable import DSHSurface

/// G-3 的可执行形式（known-gaps.md）。
///
/// 要守的行为不是「ping 发出去了」，而是**「client 半半静默死亡时，用户不会
/// 面对一个看起来正常却点不动的界面」**。所以每个用例的断言落点都在
/// `phase` / `stage`（原生插槽还在不在屏幕上），而不只是在计数器上。
@Suite("G-3 控制通道心跳：surface/ping ↔ surface/pong")
@MainActor
struct SurfaceHeartbeatTests {
    /// 一整套：通道 + 舞台 + 协调器 + 手动驱动的心跳。
    ///
    /// 心跳的 `sleeper` 被换成「睡到测试结束都不醒」：节律由测试用
    /// `probeOnce()` 逐拍推进，不依赖真实时钟；通道的 `sleeper` 只留 20ms，
    /// 让「对端不回」在毫秒级变成一次真实超时。
    private func makeStack() -> (
        coordinator: SurfaceCoordinator,
        channel: ControlChannel,
        evaluator: FakeEvaluator,
        host: NativeSlotHost,
        heartbeat: SurfaceHeartbeat,
        telemetry: RecordingTelemetry
    ) {
        let telemetry = RecordingTelemetry()
        let channel = ControlChannel(telemetry: telemetry, sleeper: { _ in
            try await Task.sleep(for: .milliseconds(20))
        })
        let evaluator = FakeEvaluator()
        evaluator.channel = channel
        channel.attach(evaluator: evaluator)
        let (host, _, _) = makeHost(telemetry: telemetry)
        let heartbeat = SurfaceHeartbeat(
            channel: channel,
            telemetry: telemetry,
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let coordinator = SurfaceCoordinator(
            channel: channel,
            host: host,
            telemetry: telemetry,
            heartbeat: heartbeat
        )
        return (coordinator, channel, evaluator, host, heartbeat, telemetry)
    }

    /// 握手 → configure → live → 挂上 W1 原生侧栏。
    private func bringUp(
        _ stack: (
            coordinator: SurfaceCoordinator,
            channel: ControlChannel,
            evaluator: FakeEvaluator,
            host: NativeSlotHost,
            heartbeat: SurfaceHeartbeat,
            telemetry: RecordingTelemetry
        ),
        answerPing: Bool = true
    ) async throws {
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id else { return nil }
            switch envelope.method {
            case ControlMethod.surfaceConfigure:
                return .success(id: id, payload: .object([
                    "applied": .array([.string(W1.workspacesSlot)]),
                    "rejected": .array([]),
                ]))
            case ControlMethod.surfacePing:
                guard answerPing else { return nil }
                return .success(id: id, payload: .object(["seq": envelope.payload["seq"] ?? .null]))
            default:
                return nil
            }
        }
        try stack.coordinator.start()
        stack.channel.receive(envelope: .event(method: ControlMethod.surfaceReady, payload: .object([
            "protocol": .number(1),
            "slots": .array([.object([
                "name": .string(W1.workspacesSlot),
                "kind": .string("single"),
                "scope": .string("root"),
            ])]),
        ])))
        try await Task.sleep(for: .milliseconds(50))
        stack.channel.receive(envelope: .event(method: ControlMethod.slotMount, payload: .object([
            "slot": .string(W1.workspacesSlot),
            "instanceId": .string("inst-1"),
            "scope": .string("root"),
            "actions": .array([.string("startSession")]),
        ])))
        #expect(stack.coordinator.phase == .live(protocolVersion: 1))
        #expect(stack.host.stage.visibleInstance(of: W1.workspacesSlot) != nil)
    }

    /// 这两个数字来自 G-3，改它们必须改文档。
    @Test("节律钉死：10s 一拍，连续 2 拍未回即判失联")
    func cadenceIsPinned() {
        #expect(SurfaceHeartbeat.interval == .seconds(10))
        #expect(SurfaceHeartbeat.missThreshold == 2)
        #expect(ControlMethod.surfacePing == "surface/ping")
        #expect(ControlMethod.surfacePong == "surface/pong")
        // ping 的预算必须短于一拍，否则丢拍判定会滑到下一拍之后。
        #expect(ControlMethod.timeout(for: ControlMethod.surfacePing) < SurfaceHeartbeat.interval)
    }

    @Test("正常心跳：ping 有回执 → healthy，原生插槽照常在屏幕上")
    func healthyHeartbeat() async throws {
        let stack = makeStack()
        try await bringUp(stack)

        #expect(await stack.heartbeat.probeOnce())
        #expect(await stack.heartbeat.probeOnce())

        #expect(stack.heartbeat.health == .healthy)
        #expect(stack.heartbeat.consecutiveMisses == 0)
        #expect(stack.heartbeat.sentPingCount == 2)
        #expect(stack.heartbeat.pongCount == 2)
        #expect(stack.heartbeat.lastPongAt != nil)
        // ping 走的是契约信封的 req，方法名是 surface/ping。
        let ping = try #require(stack.evaluator.lastRequest)
        #expect(ping.kind == .req)
        #expect(ping.method == ControlMethod.surfacePing)
        #expect(ping.payload["seq"]?.intValue == 2)
        // 心跳不该动插槽，也不该降级。
        #expect(stack.coordinator.phase == .live(protocolVersion: 1))
        #expect(stack.host.stage.visibleInstance(of: W1.workspacesSlot) != nil)
        #expect(stack.telemetry.degradations.isEmpty)
        #expect(stack.telemetry.heartbeatMisses.isEmpty)
    }

    @Test("丢 1 拍仍存活：suspect，插槽不撤，但状态必须被画出来")
    func survivesASingleMiss() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)

        #expect(await stack.heartbeat.probeOnce() == false)

        #expect(stack.heartbeat.health == .suspect(misses: 1))
        #expect(stack.heartbeat.health.isSuspect)
        // 「原生视图可交互但控制通道失联」必须显式可见，不许静默失效。
        #expect(stack.heartbeat.health.noticeText != nil)
        #expect(stack.coordinator.controlLinkHealth == .suspect(misses: 1))
        // 一拍还不判死：官方 UI 不接管，原生侧栏留在屏幕上。
        #expect(stack.coordinator.phase == .live(protocolVersion: 1))
        #expect(stack.host.stage.visibleInstance(of: W1.workspacesSlot) != nil)
        #expect(stack.telemetry.degradations.isEmpty)
        #expect(stack.telemetry.heartbeatMisses == [1])

        // 下一拍回来了 → 计数归零，不留后遗症。
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id, envelope.method == ControlMethod.surfacePing else { return nil }
            return .success(id: id, payload: .object(["seq": envelope.payload["seq"] ?? .null]))
        }
        #expect(await stack.heartbeat.probeOnce())
        #expect(stack.heartbeat.health == .healthy)
        #expect(stack.heartbeat.consecutiveMisses == 0)
    }

    @Test("丢 2 拍 → 判失联：撤下所有原生插槽，让官方 Web UI 接管")
    func twoMissesFallBackToTheOfficialWebUI() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)

        #expect(await stack.heartbeat.probeOnce() == false)
        #expect(await stack.heartbeat.probeOnce() == false)

        #expect(stack.heartbeat.health == .lost(misses: 2))
        #expect(stack.coordinator.phase == .degradedWebOnly(
            .controlLinkLost(misses: 2, interval: SurfaceHeartbeat.interval)
        ))
        // 与崩溃退位对齐：舞台清空 + 一个原生插槽都不再渲染。
        #expect(stack.host.stage.mounted.isEmpty)
        #expect(stack.coordinator.phase.rendersNativeSlots == false)
        #expect(stack.telemetry.degradations == [
            .controlLinkLost(misses: 2, interval: SurfaceHeartbeat.interval)
        ])
        #expect(stack.telemetry.heartbeatMisses == [1, 2])
        // 判死后停拍：不再往一个已经死掉的对端上发 req。
        let sentWhenLost = stack.heartbeat.sentPingCount
        #expect(sentWhenLost == 2)
    }

    @Test("判死之后 pong 回来也不自动复活（界面不许在两种实现之间抖动）")
    func doesNotFlapBackAfterLoss() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)
        #expect(await stack.heartbeat.probeOnce() == false)
        #expect(await stack.heartbeat.probeOnce() == false)
        #expect(stack.heartbeat.health.isLost)

        stack.channel.receive(envelope: .event(
            method: ControlMethod.surfacePong,
            payload: .object(["seq": .number(9)])
        ))
        #expect(stack.heartbeat.health == .lost(misses: 2))
        #expect(stack.coordinator.phase.rendersNativeSlots == false)
    }

    @Test("pong 写成单向 evt 也算活体证据（兼容 client 半的另一种写法）")
    func acceptsPongAsAnEvent() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)
        // ping 不给回执，只回一条 `evt surface/pong`。
        stack.evaluator.autoReply = { envelope in
            guard envelope.method == ControlMethod.surfacePing else { return nil }
            return .event(method: ControlMethod.surfacePong, payload: .object([
                "seq": envelope.payload["seq"] ?? .null,
            ]))
        }
        #expect(await stack.heartbeat.probeOnce())
        #expect(stack.heartbeat.health == .healthy)
        #expect(stack.heartbeat.pongCount == 1)
        // pong 不是编排事件：不许被当成未知方法记一笔拒绝。
        #expect(stack.channel.rejectedInputCount == 0)
        #expect(stack.telemetry.faults.isEmpty)
    }

    @Test("client 半反向 ping 宿主：宿主回执，并把它算作活体证据")
    func answersInboundPing() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)
        stack.evaluator.scripts.removeAll()
        stack.evaluator.autoReply = nil

        stack.channel.receive(
            text: #"{"v":1,"t":"req","id":"01J000000000000000000000AB","m":"surface/ping","p":{"seq":4}}"#
        )
        try await Task.sleep(for: .milliseconds(50))

        let reply = try #require(stack.evaluator.lastRequest)
        #expect(reply.kind == .res)
        #expect(reply.id?.rawValue == "01J000000000000000000000AB")
        #expect(reply.payload["seq"]?.intValue == 4)
        // 反向 ping 说明对端事件循环还在跑 → 不该被记成未知方法。
        #expect(stack.channel.rejectedInputCount == 0)
        #expect(stack.heartbeat.pongCount == 1)
        #expect(stack.heartbeat.health == .healthy)
    }

    @Test("回执带错的 seq → 记为 stale，但仍算活")
    func recordsStaleReplies() async throws {
        let stack = makeStack()
        try await bringUp(stack, answerPing: false)
        stack.evaluator.autoReply = { envelope in
            guard let id = envelope.id, envelope.method == ControlMethod.surfacePing else { return nil }
            return .success(id: id, payload: .object(["seq": .number(0)]))
        }
        #expect(await stack.heartbeat.probeOnce())
        #expect(stack.heartbeat.staleReplyCount == 1)
        #expect(stack.heartbeat.health == .healthy)
    }

    @Test("握手完成前不开始心跳（那时一个原生插槽都没渲染）")
    func doesNotBeatBeforeHandshake() throws {
        let stack = makeStack()
        try stack.coordinator.start()
        #expect(stack.coordinator.phase == .launching)
        #expect(stack.coordinator.controlLinkHealth == .unknown)
        #expect(stack.heartbeat.sentPingCount == 0)
        stack.coordinator.stop()
    }
}
