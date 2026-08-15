import Foundation
import UserNotifications

struct BridgeStatus: Decodable {
    let ok: Bool
    let profile: String?
    let lastTurn: LastTurn?

    struct LastTurn: Decodable {
        let type: String
        let at: String
        let title: String
        let sessionId: String?
    }
}

@MainActor
final class NotificationBridge: ObservableObject {
    private var timer: Timer?
    private var lastSeenAt: String?
    private let center = UNUserNotificationCenter.current()
    var statusURL = URL(string: "http://127.0.0.1:43180/status")!
    var notifyTestURL = URL(string: "http://127.0.0.1:43180/notify-test")!

    func start(enabled: Bool) {
        stop()
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sendTest() async {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        var request = URLRequest(url: notifyTestURL)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        present(title: "DSH Studio", body: L10n.t("通知测试", "Notification test"))
    }

    private func poll() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let status = try JSONDecoder().decode(BridgeStatus.self, from: data)
            guard let turn = status.lastTurn, turn.type.contains("end") else { return }
            if turn.at != lastSeenAt {
                let first = lastSeenAt == nil
                lastSeenAt = turn.at
                if !first {
                    present(title: turn.title, body: L10n.t("回合已结束", "Turn ended"))
                }
            }
        } catch {
            // Bridge may not be up yet.
        }
    }

    private func present(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
