import Foundation
import Testing

@testable import DSHSurface

struct SurfaceChromeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("相对时间桶对齐官方：刚刚 / 分钟 / 小时 / 天 / 月 / 年")
    func relativeTimeBuckets() {
        let origin = now.timeIntervalSince1970 * 1000
        #expect(SurfaceRelativeTime.label(updatedAt: origin, now: now) == "刚刚")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 59_000, now: now) == "刚刚")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 60_000, now: now) == "1分钟")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 90_000, now: now) == "1分钟")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 3_600_000, now: now) == "1小时")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 5 * 3_600_000, now: now) == "5小时")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 86_400_000, now: now) == "1天")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 5 * 86_400_000, now: now) == "5天")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 30 * 86_400_000, now: now) == "1个月")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 60 * 86_400_000, now: now) == "2个月")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 365 * 86_400_000, now: now) == "1年")
        #expect(SurfaceRelativeTime.label(updatedAt: origin - 800 * 86_400_000, now: now) == "2年")
    }

    @Test("秒级时间戳会先乘 1000；未来时间按刚刚")
    func relativeTimeSecondsAndFuture() {
        #expect(SurfaceRelativeTime.label(updatedAt: 1_700_000_000 - 90, now: now) == "1分钟")
        #expect(SurfaceRelativeTime.label(updatedAt: 1_700_000_000 + 60, now: now) == "刚刚")
        #expect(SurfaceRelativeTime.label(updatedAt: 0, now: now) == "53年")
    }

    @Test("草稿窗口标题是新会话，即使 selection.title 是工作区名")
    func chromeTitlePrefersDraftOverWorkspaceName() {
        let catalog = SurfaceCatalog(
            currentSessionId: "draft",
            workspaces: [
                SurfaceWorkspaceGroup(
                    workspaceId: "ws",
                    title: "Workspace",
                    path: "/tmp/ws",
                    sessions: [
                        SurfaceSessionRow(
                            sessionId: "draft",
                            title: "Workspace",
                            blank: true,
                            running: false,
                            updatedAt: 1
                        ),
                    ]
                ),
            ],
            ungrouped: []
        )
        let selection = SurfaceSelection(sessionId: "draft", path: "/tmp/ws", title: "Workspace")
        #expect(SurfaceChromeTitle.resolve(catalog: catalog, selection: selection) == "新会话")
    }

    @Test("有标题的会话用会话名；都空时回落到 DSH Studio")
    func chromeTitleSessionThenFallback() {
        let catalog = SurfaceCatalog(
            currentSessionId: "talk",
            workspaces: [
                SurfaceWorkspaceGroup(
                    workspaceId: "ws",
                    title: "Workspace",
                    path: "/tmp/ws",
                    sessions: [
                        SurfaceSessionRow(
                            sessionId: "talk",
                            title: "  pong  ",
                            blank: false,
                            running: false,
                            updatedAt: 1
                        ),
                    ]
                ),
            ],
            ungrouped: []
        )
        #expect(SurfaceChromeTitle.resolve(catalog: catalog, selection: nil) == "pong")
        #expect(
            SurfaceChromeTitle.resolve(catalog: .empty, selection: SurfaceSelection(
                sessionId: nil, path: nil, title: "  Workspace  "
            )) == "Workspace"
        )
        #expect(SurfaceChromeTitle.resolve(catalog: .empty, selection: nil) == "DSH Studio")
    }

    @Test("斜杠与空 path 是同一页；加载中 url 为 nil 不算同页")
    func samePageNormalizesSlash() {
        let wanted = URL(string: "http://127.0.0.1:3099")!
        #expect(SurfacePageURL.same(URL(string: "http://127.0.0.1:3099/"), as: wanted))
        #expect(SurfacePageURL.same(wanted, as: wanted))
        #expect(!SurfacePageURL.same(nil, as: wanted))
        #expect(!SurfacePageURL.same(URL(string: "http://127.0.0.1:3100"), as: wanted))
        #expect(!SurfacePageURL.same(URL(string: "http://127.0.0.1:3099/other"), as: wanted))
        #expect(SurfacePageURL.normalize("") == "/")
        #expect(SurfacePageURL.normalize("/") == "/")
    }

    @Test("WKErrorDomain 5 是可忽略的 Promise 桥接失败")
    func unsupportedEvaluateResult() {
        let ignore = NSError(domain: "WKErrorDomain", code: 5)
        let other = NSError(domain: "WKErrorDomain", code: 1)
        #expect(SurfaceEvaluate.isUnsupportedResult(ignore))
        #expect(!SurfaceEvaluate.isUnsupportedResult(other))
        #expect(!SurfaceEvaluate.isUnsupportedResult(NSError(domain: "NSURLErrorDomain", code: 5)))
    }
}
