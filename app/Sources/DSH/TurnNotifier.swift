import DSHKit
import Foundation
import UserNotifications

/// Tells you when the agent finished, or when it is waiting on you.
///
/// This is the structural advantage a desktop has over a browser tab, so it is
/// worth getting right rather than bolting on: a turn takes minutes, you will
/// look away, and having to click back into the app to discover it finished
/// wastes exactly the time the agent saved.
///
/// It stays quiet while the window is focused — a notification for something
/// you are already watching is noise, and noise is what gets notifications
/// switched off.
@MainActor
@Observable
final class TurnNotifier {
    private(set) var pendingApprovals: Int = 0
    private(set) var lastEvent: String?

    private var authorized = false
    private var task: Task<Void, Never>?

    /// Non-bundled builds (a bare `swift run`) have no bundle identifier, and
    /// UNUserNotificationCenter traps rather than failing when asked for one.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    var isWindowFocused: Bool = true

    func start(baseURL: URL) {
        task?.cancel()
        pendingApprovals = 0

        if canNotify {
            Task {
                authorized = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])) ?? false
            }
        }

        task = Task { [weak self] in
            let subscription = MuxStream.subscribe(baseURL: baseURL)
            defer { subscription.cancel() }
            do {
                for try await envelope in subscription.frames {
                    guard let self else { return }
                    self.handle(envelope)
                }
            } catch {
                self?.record("下行流断开：\(error)")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pendingApprovals = 0
    }

    private func handle(_ envelope: MuxEnvelope) {
        if envelope.pendingApproval != nil {
            pendingApprovals += 1
            // Always notify for approvals, focused or not: this one is blocking
            // the agent, and a silent block is indistinguishable from a hang.
            post(title: "需要你批准", body: envelope.pendingApproval?.reason ?? "Agent 请求扩大沙箱权限")
            record("approval/requested")
            return
        }
        if case .approvalResolved = envelope.frame {
            pendingApprovals = max(0, pendingApprovals - 1)
            return
        }
        if case .sessionEvent(let payload) = envelope.frame, payload.event.type == "turn/end" {
            record("turn/end")
            guard !isWindowFocused else { return }
            post(title: "这一轮跑完了", body: "回到 Studio 看结果")
        }
    }

    private func record(_ event: String) { lastEvent = event }

    private func post(title: String, body: String) {
        guard canNotify, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
