import Foundation

/// Most mux frames are pure pushes. These two are server-requests: the agent is
/// blocked until one is answered, and an unanswered one is not an error state
/// anywhere — it is just a turn that never finishes.
///
/// The rpcId is carried alongside the payload on purpose. An answer must echo
/// the frame's own id and must never mint one, so the two are kept together
/// rather than left to a caller to pair up correctly.
public struct PendingApproval: Sendable, Hashable {
    public let rpcId: RpcId
    public let request: MuxFrameApprovalRequested

    public var sessionId: String { request.sessionId }
    public var toolName: String { request.toolName }
    /// Why the agent needs an escalation — the single most useful thing to show
    /// a user who is deciding whether to allow it.
    public var reason: String? { request.reason }
}

public struct PendingQuestion: Sendable, Hashable {
    public let rpcId: RpcId
    public let request: MuxFrameQuestionRequested

    public var sessionId: String { request.sessionId }
    public var questions: [AskUserQuestionItem] { request.questions }
}

/// The only two outcomes a client may give. `cancelled` and `unavailable` are
/// host-side outcomes and deliberately absent here.
public enum ApprovalDecision: Sendable {
    case allowOnce
    case reject

    var wireValue: ApprovalResponsePayloadOutcome {
        switch self {
        case .allowOnce: .allowedOnce
        case .reject: .rejected
        }
    }
}

extension MuxEnvelope {
    /// Non-nil when this frame blocks the agent until answered.
    public var pendingApproval: PendingApproval? {
        guard case .approvalRequested(let request) = frame else { return nil }
        return PendingApproval(rpcId: rpcId, request: request)
    }

    public var pendingQuestion: PendingQuestion? {
        guard case .questionRequested(let request) = frame else { return nil }
        return PendingQuestion(rpcId: rpcId, request: request)
    }
}

extension ApiClient {
    /// Answers a tool-approval request. Until this lands, the host's
    /// `approval.request()` promise is still pending and the turn cannot move.
    @discardableResult
    public func decide(_ approval: PendingApproval, _ decision: ApprovalDecision) async throws -> RpcReceipt {
        try await respond(
            to: approval.rpcId,
            with: ApprovalResponsePayload(
                sessionId: approval.sessionId,
                approvalId: approval.request.approvalId,
                outcome: decision.wireValue
            )
        )
    }

    /// Answers an `ask_user` request. Same blocking property as approvals.
    @discardableResult
    public func answer(
        _ question: PendingQuestion,
        with answers: [AskUserQuestionAnswerAnswersItem]
    ) async throws -> RpcReceipt {
        try await respond(
            to: question.rpcId,
            with: QuestionResponsePayload(
                sessionId: question.sessionId,
                answer: AskUserQuestionAnswer(answers: answers)
            )
        )
    }
}
