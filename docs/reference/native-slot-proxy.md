# Reference — `NativeSlotProxy` 与遮蔽注册

这份文件把 [ARCHITECTURE.md](../../ARCHITECTURE.md) 里的机制写成可评审的代码。它是**参考实现**（annotated reference），不是本分支的产物 —— 本分支只交付设计。

放在这里的目的：让「逐个替换」这件事从概念变成可以逐行争论的东西。如果这段代码不成立，整套设计就不成立。

---

## 1. Web 侧：唯一的通用代理组件

整个 client 半只有这一个组件。它不认识任何具体插槽 —— 没有 `if (slot === 'sidebar')`。

```tsx
// packages/studio-client/src/client/native-slot.tsx
import { useEffect, useLayoutEffect, useRef } from 'react'
import { ulid } from './ulid.ts'
import type { Bridge } from './bridge.ts'

type Placement = 'evacuated' | 'overlay'

/**
 * 为一个插槽生成代理组件。
 *
 * 职责边界（见 migration-playbook.md §6）：
 *   - 上报生命周期与 props（编排）
 *   - overlay 时上报几何
 *   - 其他一概不做：不取领域数据、不缓存状态、不查 DOM、不注入 CSS
 */
export function nativeSlot(
  bridge: Bridge,
  slot: string,
  placement: Placement,
  scope: 'root' | 'session' | 'session-maybe',
) {
  return function NativeSlotProxy(props: Record<string, unknown>) {
    const idRef = useRef<string>()
    const hostRef = useRef<HTMLDivElement>(null)

    // ── 挂载 / 卸载 ────────────────────────────────────────────
    // 一个 instanceId 对应原生侧一个视图实例。keyed / list 插槽会
    // 同时存在多个实例，所以绑定的是 instanceId 而不是 slot 名。
    useEffect(() => {
      const instanceId = ulid()
      idRef.current = instanceId
      bridge.emit('slot/mount', {
        slot,
        instanceId,
        key: props.key ?? undefined,
        scope,
        props: serializeOrchestration(props),
      })
      return () => {
        bridge.emit('slot/unmount', { instanceId })
        idRef.current = undefined
      }
    }, [])

    // ── props 变化 ────────────────────────────────────────────
    // 浅 diff 后只发变化字段。函数类型的 props 不过桥（见 §2）。
    const prevRef = useRef<Record<string, unknown>>({})
    useEffect(() => {
      if (!idRef.current) return
      const next = serializeOrchestration(props)
      const patch = shallowDiff(prevRef.current, next)
      prevRef.current = next
      if (Object.keys(patch).length > 0) {
        bridge.emit('slot/props', { instanceId: idRef.current, props: patch })
      }
    }, [props])

    // ── 几何（仅 overlay）────────────────────────────────────
    useLayoutEffect(() => {
      if (placement !== 'overlay' || !hostRef.current) return
      const el = hostRef.current

      // ADR-0003 的可执行形式：检测祖先是否为滚动容器，并把
      // 结论如实上报。宿主收到 overlay + scrollable 组合会直接
      // 拒绝并报错 —— 让违规在开发期崩，而不是漂移给用户看。
      const scrollable = hasScrollableAncestor(el)

      const report = () => {
        const r = el.getBoundingClientRect()
        bridge.emit('slot/rect', {
          instanceId: idRef.current,
          rect: { x: r.x, y: r.y, w: r.width, h: r.height },
          scrollable,
        })
      }
      report()
      const ro = new ResizeObserver(report)
      ro.observe(el)
      return () => ro.disconnect()
    }, [])

    // ── 渲染：两种落位，二选一 ────────────────────────────────
    if (placement === 'evacuated') {
      // 该区域的屏幕面积归原生 chrome 所有，Web 侧不占位。
      return <div data-studio-slot={slot} style={{ display: 'none' }} />
    }
    // overlay：等尺寸透明占位，撑住 Web 布局。
    return <div ref={hostRef} data-studio-slot={slot} style={{ visibility: 'hidden' }} />
  }
}
```

### 关于 `serializeOrchestration`

这个函数是 [ADR-0002](../adr/0002-domain-data-bypasses-the-webview.md) 的执行点，也是最容易被慢慢腐蚀的地方：

```ts
// 白名单，不是黑名单。允许过桥的只有编排性字段。
const ORCHESTRATION_KEYS = new Set([
  'collapsed', 'selected', 'expanded', 'width', 'disabled',
  'placeholder', 'variant', 'order', 'label',
])

function serializeOrchestration(props: Record<string, unknown>) {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(props)) {
    if (typeof v === 'function') continue        // 回调不过桥，走 slot/invoke
    if (!ORCHESTRATION_KEYS.has(k)) continue     // 领域数据不过桥，走数据通道
    out[k] = v
  }
  return out
}
```

**用白名单而不是黑名单**是刻意的。黑名单会在几十次插槽迁移里被一点点掏空 —— 每次都是「这个字段挺小的，先过桥吧」。白名单让每一次新增都变成一次显式的、需要在 review 里辩护的改动。

---

## 2. 回调怎么办：`slot/invoke`

官方插槽的 `owner` props 里有回调（例如侧栏的 `startSession`、`toggleSidebar`）。它们**不能**序列化过桥，但原生视图上的点击必须能触发它们。

做法是在 Web 侧留一张实例回调表，原生用 `slot/invoke` 按名字回调：

```ts
// 挂载时记下这个实例暴露了哪些动作
const actions = new Map<string, Record<string, Function>>()

// 在 NativeSlotProxy 的 mount effect 里
actions.set(instanceId, pickFunctions(props))
bridge.emit('slot/mount', { /* …, */ actions: Object.keys(pickFunctions(props)) })

// 处理来自原生的调用
bridge.handle('slot/invoke', ({ instanceId, action, args }) => {
  const fns = actions.get(instanceId)
  if (!fns) throw bridgeError('slot_not_mounted')
  const fn = fns[action]
  if (!fn) throw bridgeError('unknown_method')
  return fn(...(args ?? []))   // 只转发动作，不搬运数据
})
```

注意 `slot/mount` 里带的是 **`actions` 的名字列表**，不是函数。原生侧据此知道「这个插槽实例能做什么」，UI 上该显示哪些可交互控件。

安全边界（见 [bridge-contract.md §5](../bridge-contract.md)）：`slot/invoke` 只能触达 manifest 中声明为 `native` 的插槽实例的注入面，不能任意调 `ctx`。

---

## 3. 遮蔽注册：manifest 驱动

这里是 [ADR-0001](../adr/0001-slot-shadowing-over-css-hiding.md) 与 [surface-manifest.md §4](../surface-manifest.md) 的落地。

```ts
// packages/studio-client/src/client/index.ts
export const inject = ['slots']

export function apply(ctx: Context, config: Config) {
  const bridge = createBridge(ctx)

  // 握手：把实测到的插槽表交给宿主做运行时漂移检测
  bridge.emit('surface/ready', {
    protocol: 1,
    slots: surveyDeclaredSlots(ctx.slots),
  })

  // 崩溃退位遥测 —— 官方把 onEntryError 注为 host 的监管缝。
  // 我们的条目崩了 → 官方实现自动接管（ADR-0004），但必须记账。
  ctx.effect(() => ctx.slots.onEntryError((key, _entry, error, info) => {
    bridge.emit('slot/error', {
      slot: key, error: String(error), abdicated: info.abdicated,
    })
  }), 'studio: slot error telemetry')

  bridge.handle('surface/configure', ({ manifest }) => applyManifest(ctx, bridge, manifest))
  bridge.handle('surface/reconfigure', ({ patch }) => applyManifest(ctx, bridge, patch))
}

function applyManifest(ctx: Context, bridge: Bridge, manifest: Manifest) {
  const applied: string[] = []
  const rejected: Array<{ slot: string; reason: string }> = []

  for (const [slot, entry] of Object.entries(manifest)) {
    // 规则 1/2：未列出或 web → 不注册任何东西。
    // 注意不是「注册一个空组件」—— 那会占掉 cell，官方就渲染不出来了。
    if (entry.mode === 'web') { disposeOf(slot); continue }

    // 规则 6：声明即占有。赢下一个声明了子槽的插槽，就得原样
    // 声明它的全部子槽，否则别的插件往子槽注册时会抛错。
    // 缺一个 → 整条拒绝，不 partial 应用。
    const children = declaredChildrenOf(slot)
    if (entry.mode !== 'mirrored' && !canDeclareAll(children)) {
      rejected.push({ slot, reason: 'slot_not_declared' })
      continue
    }

    // 规则 3/4：priority 决定输赢。
    //   mirrored → 更高 priority「陪跑」：拿 props 与生命周期，
    //              但官方仍然赢渲染权，用于对照验证。
    //   native/retired → 更低 priority 遮蔽官方。
    const priority = entry.mode === 'mirrored' ? +1 : (entry.priority ?? -1)

    disposeOf(slot)
    keep(slot, ctx.effect(() => ctx.slots.register(
      { name: slot, priority, children },
      nativeSlot(bridge, slot, entry.placement ?? 'evacuated', scopeOf(slot)),
    ), `studio: shadow ${slot} @${priority}`))

    applied.push(slot)
  }

  return { applied, rejected }
}
```

三处值得单独看：

- **`mode: web` 是「不注册」，不是「注册空组件」。** 注册空组件会赢下 cell 并渲染空白 —— 这正是我们要避免的失败模式。
- **`mirrored` 用 `+1`「陪跑」。** 更高 priority 反而不赢渲染权，于是我们能在真实数据上跑原生实现而官方仍然正常显示。这完全在官方语义内，不需要任何额外机制。
- **热切换 = `ctx.effect` 的撤销与重建。** 不刷新页面、不重启 runtime，因为注册本来就是可逆副作用。

---

## 4. 原生侧：装配与拒绝

```swift
// apps/macos/Sources/DSHSurface/NativeSlotHost.swift

/// 按 slot 名注册视图工厂；实例按 instanceId 追踪。
/// 注意：视图工厂只拿到编排 props，领域数据由视图自己从
/// DSHClient（数据通道）取 —— DSHSurface 不碰领域数据。
final class NativeSlotHost {
    private var factories: [String: (SlotInstance) -> AnyView] = [:]
    private var live: [String: SlotInstance] = [:]

    func register(_ slot: String, _ make: @escaping (SlotInstance) -> AnyView) {
        factories[slot] = make
    }

    func handle(_ event: SurfaceEvent) throws {
        switch event {
        case let .mount(slot, instanceId, key, scope, props, actions):
            guard let make = factories[slot] else {
                // manifest 说要原生，但宿主没有实现 → 大声失败。
                throw SurfaceError.noNativeImplementation(slot)
            }
            let inst = SlotInstance(slot: slot, id: instanceId, key: key,
                                    scope: scope, props: props, actions: actions)
            live[instanceId] = inst
            mount(make(inst), for: inst)

        case let .rect(instanceId, rect, scrollable):
            // ADR-0003 的执行点：滚动容器内不许 overlay。
            // 不「尽力渲染」，直接失败 —— 漂移是视觉撕裂，
            // 比崩溃更难发现、对用户更像坏产品。
            if scrollable {
                throw SurfaceError.overlayInsideScrollContainer(live[instanceId]?.slot ?? "?")
            }
            position(instanceId, to: rect)

        case let .props(instanceId, patch):
            live[instanceId]?.apply(patch)          // 晚到/早到均容忍，丢弃即可

        case let .unmount(instanceId):
            live.removeValue(forKey: instanceId).map(unmountView)

        case let .error(slot, _, abdicated):
            telemetry.slotFailed(slot, abdicated: abdicated)
            // abdicated == true → 官方 Web 实现已自动接管这一格。
            // 不需要我们做任何补救，但必须记账并告警。
        }
    }
}
```

原生视图自己怎么拿数据（注意它不认识 WebView）：

```swift
struct WorkspacesRailView: View {
    let instance: SlotInstance          // 编排：collapsed / selected
    @EnvironmentObject var client: DSHClient   // 领域：loopback 数据通道

    var body: some View {
        SessionTree(sessions: client.sessions, selected: instance.props.selected)
            .onSelect { id in
                client.rpc(.sessionOpen(id))            // 领域动作 → 数据通道
            }
            .onNewSession {
                instance.invoke("startSession")          // 注入面回调 → slot/invoke
            }
    }
}
```

这两个 `on*` 分支就是整套架构的分界线：**数据与领域动作走 loopback，只有必须由 Web 侧 `ctx` 完成的回调才过控制通道。**

---

## 5. 这段代码要证明的四件事

1. **替换一个插槽 = manifest 加一行 + 写一个 SwiftUI 视图。** Web 侧零改动（`NativeSlotProxy` 不认识具体插槽）。
2. **回退 = manifest 改一行。** 官方条目一直在 priority 0 排队。
3. **崩溃自动回落是白拿的。** `onEntryError` + 官方 `abdicate`，我们只负责记账。
4. **client 半可以整体删除。** 它只有代理组件、桥、manifest 解析三样东西，且不持有任何领域状态 —— W8 删掉它不动数据路径（[ADR-0002](../adr/0002-domain-data-bypasses-the-webview.md)）。

如果实现过程中发现某个插槽需要打破这四条中的任何一条，那不是实现细节问题，是设计需要修正 —— 按 [migration-playbook.md §3](../migration-playbook.md) 升粒度，或者回来改这份设计。
