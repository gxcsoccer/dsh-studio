import DSHKit
import Foundation

/// How the bridge reaches the page. The production conformance is a WKWebView;
/// tests inject a recorder.
@MainActor
public protocol SurfaceTransport: AnyObject {
    func evaluate(_ javascript: String) async throws
}

/// Request/response across the chrome channel, plus the events the page
/// originates (`ready`, `selection`).
///
/// Native may want to open a workspace before the client plugin has applied
/// — first launch, or a reload after ⌘⇧R. Requests wait for `ready` rather
/// than racing `evaluateJavaScript` against a hook that is not there yet.
@MainActor
public final class SurfaceBridge {
    public var readyTimeout: Duration = .seconds(15)

    public private(set) var isReady = false
    public var onSelection: ((SurfaceSelection) -> Void)?
    public var onCatalog: ((SurfaceCatalog) -> Void)?

    private weak var transport: (any SurfaceTransport)?
    private var pending: [String: CheckedContinuation<SurfaceFrame, Error>] = [:]
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private let decoder = JSONDecoder()

    public init() {}

    public func attach(_ transport: any SurfaceTransport) {
        self.transport = transport
    }

    public func detach() {
        transport = nil
        isReady = false
        failPending(.detached)
        failReadyWaiters(.detached)
    }

    /// The document is going away. In-flight RPCs cannot be answered by the
    /// next generation; waiters for `ready` stay, because that is exactly
    /// what a reload produces next.
    public func notePageReset() {
        isReady = false
        failPending(.pageReset)
    }

    public func receive(_ body: Any) {
        guard let data = encodeBody(body) else { return }
        guard let frame = try? decoder.decode(SurfaceFrame.self, from: data) else { return }
        guard frame.v == SurfaceFrame.version else { return }
        handle(frame)
    }

    public func openWorkspace(path: String) async throws -> OpenWorkspaceResult {
        let value = try await request(
            method: "openWorkspace",
            payload: .object(["path": .string(path)])
        )
        return try decodeValue(value)
    }

    public func openSession(sessionId: String) async throws {
        _ = try await request(
            method: "openSession",
            payload: .object(["sessionId": .string(sessionId)])
        )
    }

    public func startSession(workspaceId: String? = nil) async throws {
        var fields: [String: JSONValue] = [:]
        if let workspaceId { fields["workspaceId"] = .string(workspaceId) }
        _ = try await request(method: "startSession", payload: .object(fields))
    }

    public func openSettings() async throws {
        _ = try await request(method: "openSettings", payload: .object([:]))
    }

    public func archiveSession(sessionId: String) async throws {
        _ = try await request(
            method: "archiveSession",
            payload: .object(["sessionId": .string(sessionId)])
        )
    }

    public func renameSession(sessionId: String, title: String) async throws {
        _ = try await request(
            method: "renameSession",
            payload: .object([
                "sessionId": .string(sessionId),
                "title": .string(title),
            ])
        )
    }

    public func forkSession(sessionId: String) async throws {
        _ = try await request(
            method: "forkSession",
            payload: .object(["sessionId": .string(sessionId)])
        )
    }

    // MARK: - Internals

    private func request(method: String, payload: JSONValue) async throws -> JSONValue {
        try await waitUntilReady()
        guard transport != nil else { throw SurfaceError.detached }

        let id = UUID().uuidString
        let frame = SurfaceFrame.request(id: id, method: method, payload: payload)
        let reply: SurfaceFrame = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await self.send(frame, failing: id) }
        }
        if reply.ok == true, let value = reply.value {
            return value
        }
        throw SurfaceError.remote(reply.error ?? "surface request failed")
    }

    private func send(_ frame: SurfaceFrame, failing id: String) async {
        do {
            guard let transport else { throw SurfaceError.detached }
            try await transport.evaluate(SurfaceScript.dispatch(frame))
        } catch {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            }
        }
    }

    private func handle(_ frame: SurfaceFrame) {
        switch frame.type {
        case .res:
            guard let id = frame.id, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: frame)
        case .evt:
            switch frame.method {
            case "ready":
                markReady()
            case "selection":
                onSelection?(selection(from: frame.payload))
            case "catalog":
                if let catalog = catalog(from: frame.payload) {
                    onCatalog?(catalog)
                }
            default:
                break
            }
        case .req:
            // The page does not originate requests in v1.
            break
        }
    }

    private func markReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume() }
    }

    private func waitUntilReady() async throws {
        if isReady { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if isReady {
                continuation.resume()
                return
            }
            readyWaiters[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: self.readyTimeout)
                if let waiter = self.readyWaiters.removeValue(forKey: id) {
                    waiter.resume(throwing: SurfaceError.notReady)
                }
            }
        }
    }

    private func failPending(_ error: SurfaceError) {
        let inflight = pending
        pending.removeAll()
        for (_, continuation) in inflight { continuation.resume(throwing: error) }
    }

    private func failReadyWaiters(_ error: SurfaceError) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
    }

    private func selection(from payload: JSONValue?) -> SurfaceSelection {
        SurfaceSelection(
            sessionId: payload?["sessionId"]?.stringValue,
            path: payload?["path"]?.stringValue,
            title: payload?["title"]?.stringValue
        )
    }

    private func catalog(from payload: JSONValue?) -> SurfaceCatalog? {
        guard let payload else { return nil }
        return try? decodeValue(payload)
    }

    private func decodeValue<T: Decodable>(_ value: JSONValue) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder().encode(value))
    }

    private func encodeBody(_ body: Any) -> Data? {
        if let text = body as? String { return Data(text.utf8) }
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }
}
