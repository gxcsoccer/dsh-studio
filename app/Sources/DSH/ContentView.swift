import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .checking:
                StatusView(title: "正在检查环境", detail: nil)
            case .blocked(let preflight):
                PreflightView(preflight: preflight)
            case .needsWorkspace:
                WorkspaceEmptyState()
            case .launching(let message):
                StatusView(title: message, detail: model.workspaces.current?.path)
            case .ready(let url):
                SurfaceWebView(url: url)
            case .failed(let summary, let detail):
                FailureView(summary: summary, detail: detail)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

// MARK: - States

private struct StatusView: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title)，\($0)" } ?? title)
    }
}

/// The first-run gate. Every failed check carries an action, because a list of
/// diagnoses is not a first run — it is homework.
private struct PreflightView: View {
    @Environment(AppModel.self) private var model
    let preflight: Preflight

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("还差一点就能开始").font(.title2).bold()
                Text("Studio 用的是你机器上官方的 DeepSeek Harness 运行时。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(preflight.checks) { check in
                    CheckRow(check: check)
                    if check.id != preflight.checks.last?.id { Divider() }
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("重新检查") { Task { await model.boot() } }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
    }
}

private struct CheckRow: View {
    let check: Preflight.Check

    var body: some View {
        HStack(spacing: 12) {
            // Never colour alone: state is spelled out in the symbol and in the
            // trailing text as well.
            Image(systemName: check.isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(check.isOK ? Color.green : Color.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                switch check.state {
                case .ok(let note):
                    Text(note).font(.caption).foregroundStyle(.secondary)
                case .missing(let action, _):
                    Text(action).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .missing(_, let url) = check.state, let url {
                Link("打开说明", destination: url).font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text("还没有项目落在 Studio 里").font(.title3).bold()
            Text("选一个项目目录，Agent 会在里面工作。")
                .font(.callout).foregroundStyle(.secondary)
            Button("打开文件夹…") {
                if let url = model.workspaces.chooseDirectory() {
                    Task { await model.open(workspace: url) }
                }
            }
            .keyboardShortcut(.defaultAction)

            if !model.workspaces.recents.isEmpty {
                Divider().frame(width: 240)
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.workspaces.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { Task { await model.open(workspace: url) } }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct FailureView: View {
    @Environment(AppModel.self) private var model
    let summary: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("运行时没能起来").font(.title3).bold()
            Text(summary).font(.callout)

            // The child's own output, verbatim. A preview-stage runtime fails in
            // ways no wrapper can usefully paraphrase, and paraphrasing is how
            // the actual cause gets lost.
            ScrollView {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("重试") { Task { await model.restart() } }
                    .keyboardShortcut(.defaultAction)
                Button("换个工作区") {
                    if let url = model.workspaces.chooseDirectory() {
                        Task { await model.open(workspace: url) }
                    }
                }
                Spacer()
            }
        }
        .padding(28)
    }
}
