import Foundation
import DSHKit

/// 编译期的插槽契约快照（ARCHITECTURE.md §7 的运行时那一半）。
///
/// `surface/ready` 带来 client 半**实测到的**插槽表，我们和这份快照比对。
/// 上游改了插槽表就大声失败/告警，而不是等运行时白屏。
public struct SlotContractSnapshot: Hashable, Sendable {
    public struct Expectation: Hashable, Sendable {
        public let name: String
        public let kind: SlotKind
        public let scope: SlotScope

        public init(name: String, kind: SlotKind, scope: SlotScope) {
            self.name = name
            self.kind = kind
            self.scope = scope
        }
    }

    public let expectations: [Expectation]

    public init(expectations: [Expectation]) {
        self.expectations = expectations
    }

    /// W1 关心的插槽（slot-map.md §2 / §3，实读上游源码）。
    public static let w1 = SlotContractSnapshot(expectations: [
        Expectation(name: "sidebar", kind: .single, scope: .root),
        Expectation(name: "sidebar.workspaces", kind: .single, scope: .root),
        Expectation(name: "sidebar.settings", kind: .single, scope: .root),
        Expectation(name: "sidebar.footer.action", kind: .list, scope: .root),
        Expectation(name: "sidebar.workspaces.directoryFlow", kind: .single, scope: .root),
    ])

    /// 比对实测表。只对**我们打算接管**的插槽较真；上游新增插槽不算漂移
    /// （surface-manifest.md §4 规则 1：未列出 = web，自动落到安全侧）。
    public func drift(against measured: [DeclaredSlot], interestedIn slots: Set<String>) -> SlotContractDrift? {
        var missing: [String] = []
        var mismatched: [SlotContractDrift.Mismatch] = []
        let byName = Dictionary(measured.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for expectation in expectations where slots.contains(expectation.name) {
            guard let actual = byName[expectation.name] else {
                missing.append(expectation.name)
                continue
            }
            if actual.kind != expectation.kind || actual.scope != expectation.scope {
                mismatched.append(SlotContractDrift.Mismatch(
                    name: expectation.name,
                    expected: "\(expectation.kind.rawValue)/\(expectation.scope.rawValue)",
                    actual: "\(actual.kind.rawValue)/\(actual.scope.rawValue)"
                ))
            }
        }
        // 我们要接管、但快照里根本没有这个插槽 → 也算漂移（配置引用了未知插槽）。
        let known = Set(expectations.map(\.name))
        for slot in slots.sorted() where !known.contains(slot) {
            mismatched.append(SlotContractDrift.Mismatch(name: slot, expected: "declared in snapshot", actual: "absent"))
        }
        guard !missing.isEmpty || !mismatched.isEmpty else { return nil }
        return SlotContractDrift(missing: missing.sorted(), mismatched: mismatched)
    }
}

/// 一次契约漂移。
public struct SlotContractDrift: Hashable, Sendable, CustomStringConvertible {
    public struct Mismatch: Hashable, Sendable {
        public let name: String
        public let expected: String
        public let actual: String
    }

    public let missing: [String]
    public let mismatched: [Mismatch]

    public var description: String {
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("slots we target are absent upstream: \(missing.joined(separator: ", "))")
        }
        for mismatch in mismatched {
            parts.append("`\(mismatch.name)` expected \(mismatch.expected), measured \(mismatch.actual)")
        }
        return parts.joined(separator: "; ")
    }
}
