import Foundation

/// One downlink frame plus the rpcId it arrived under. The id matters: for
/// answerable frames (`approval/requested`, `question/requested`) the answer
/// must echo it back verbatim.
public struct MuxEnvelope: Sendable {
    public let rpcId: RpcId
    public let frame: MuxFrame
}

/// Something the host reported mid-stream, as opposed to a normal close.
public struct MuxStreamFailure: Error, Sendable {
    public let error: RpcError
}

/// The all-session mux downlink.
///
/// On the official web carrier this is a WebSocket: `GET /api/events.mux`
/// answers 426 and demands an upgrade. Our own carrier will serve the same
/// frames as SSE instead — same contract, different pipe, which is why the
/// frame type is shared and only this file changes.
/// A live downlink. Closing it is an explicit operation rather than a
/// side effect of deallocation: "the client went away without answering" is a
/// state the product has to handle correctly, so tests need to be able to
/// produce it deliberately.
public final class MuxSubscription: Sendable {
    public let frames: AsyncThrowingStream<MuxEnvelope, any Error>
    private let close: @Sendable () -> Void

    init(frames: AsyncThrowingStream<MuxEnvelope, any Error>, close: @escaping @Sendable () -> Void) {
        self.frames = frames
        self.close = close
    }

    /// Drops the connection the way quitting the app would.
    public func cancel() { close() }

    deinit { close() }
}

public enum MuxStream {
    private struct Downlink: Decodable {
        let rpcId: RpcId
        let payload: MuxFrame
    }

    /// Decodes one downlink message. Exposed so tests can replay recorded
    /// traffic through the exact path the live stream uses — a decoder that is
    /// only ever exercised by a live socket is a decoder nothing checks.
    public static func decode(_ data: Data) throws -> MuxEnvelope {
        let downlink = try JSONDecoder().decode(Downlink.self, from: data)
        return MuxEnvelope(rpcId: downlink.rpcId, frame: downlink.payload)
    }

    public static func subscribe(
        baseURL: URL,
        session: URLSession = .shared
    ) -> MuxSubscription {
        var handle: (@Sendable () -> Void)?
        let frames = open(baseURL: baseURL, session: session) { handle = $0 }
        return MuxSubscription(frames: frames, close: handle ?? {})
    }

    public static func open(
        baseURL: URL,
        session: URLSession = .shared,
        onCancelHandle: (@escaping @Sendable () -> Void) -> Void = { _ in }
    ) -> AsyncThrowingStream<MuxEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            var components = URLComponents(url: baseURL.appending(path: "/api/events.mux"), resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            let socket = session.webSocketTask(with: components.url!)

            let pump = Task {
                socket.resume()
                do {
                    while !Task.isCancelled {
                        let data: Data
                        switch try await socket.receive() {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let raw): data = raw
                        @unknown default: continue
                        }

                        let envelope = try decode(data)
                        continuation.yield(envelope)

                        // A mid-stream host failure closes the stream. Finishing
                        // normally here would read as a clean disconnect, which is
                        // exactly the confusion this frame exists to prevent.
                        if case .streamError(let payload) = envelope.frame {
                            continuation.finish(throwing: MuxStreamFailure(error: payload.error))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let shutdown: @Sendable () -> Void = {
                pump.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
            onCancelHandle(shutdown)
        }
    }
}
