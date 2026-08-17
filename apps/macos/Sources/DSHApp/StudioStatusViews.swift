import SwiftUI
import DSHKit
import DSHClient
import DSHSurface

/// 与 runtime / 官方 UI 的连接状态条。
///
/// bridge-contract.md §2.3：「宿主**必须**能显示『与 runtime 失联』态」——
/// 这是从 `codex/agent-sidebar` 分支继承的教训：Web UI 断连时恰好也没法告诉
/// 你它断连了。所以断连不是一个 console 里的 warning，是屏幕上的一条横幅。
struct StudioStatusBar: View {
    let linkBanner: String?
    let controlNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            if let linkBanner {
                row(icon: "bolt.horizontal.circle", text: linkBanner, tint: .red)
                    .accessibilityLabel("数据通道状态")
                    .accessibilityValue(linkBanner)
            }
            if let controlNotice {
                // G-3：控制通道失联要么已经回落官方 UI，要么正在 suspect —— 
                // 两种都必须说出来，不许静默失效。
                row(icon: "exclamationmark.triangle", text: controlNotice, tint: .orange)
                    .accessibilityLabel("控制通道状态")
                    .accessibilityValue(controlNotice)
            }
        }
    }

    private func row(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}

/// 官方 UI 壳还没有地址时，右半屏显示这个 —— 而不是一块白色 WebView。
///
/// 「与 runtime 失联必须能显示」这条要求同时管着这一格：如果 `dsh` 没起、
/// 或者 studio profile 没装，用户应该看到人话和下一步，而不是空白。
struct RuntimeOfflineView: View {
    let detail: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("尚未连接到 dsh runtime")
                .font(.title3)
            Text(detail ?? "没有找到 $DSH_HOME/studio/bridge.json")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("下一步：")
                    .font(.caption.bold())
                Text("1. 启动 runtime：`npx @deepseek-ai/dsh web`")
                Text("2. 或直接指定壳地址：`DSH_STUDIO_SHELL_URL=http://127.0.0.1:3000`")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            Button("重新查找 runtime", action: onRetry)
                .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("与 dsh runtime 失联")
        .accessibilityValue(detail ?? "runtime 未运行")
    }
}
