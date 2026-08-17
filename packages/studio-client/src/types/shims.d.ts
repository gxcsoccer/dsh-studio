/**
 * Local type shims for the upstream `deepseek-harness` packages.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * `studio-client` is a Cordis **client** plugin that lives outside the dsh
 * monorepo, and the upstream packages are not published to a registry this
 * subtree can install from. Every declaration below is transcribed from the
 * upstream source (paths cited per block) and narrowed to exactly the surface
 * this package touches. Nothing here is invented: when upstream changes, this
 * file is the single place that has to be re-transcribed, and the mismatch
 * shows up as a compile error rather than a runtime white screen
 * (ARCHITECTURE.md §7).
 *
 * DELIBERATE DIVERGENCE (documented, not accidental)
 * -------------------------------------------------
 * Upstream `SlotRegistry.register` is a pair of overloads statically keyed on
 * `keyof SlotMap & string`, with the component checked against
 * `ComposedProps<…>`. Studio's registration keys come from a runtime manifest
 * (surface-manifest.md), so a statically keyed face cannot express them. The
 * shim therefore declares the **erased** registration face that upstream's own
 * runtime uses internally for exactly the same reason —
 * `ErasedRegisterOptions` / `ErasedCore` in
 * `packages/client/runtime/src/client/slots.ts`. Static contract checking is
 * not lost: it moves to the pinned per-slot contract modules
 * (`src/client/slots/*.ts`), which assert against the typed upstream props
 * declarations below.
 */

declare module '@deepseek-ai/cordis' {
  /** Disposer returned by a synchronous effect body (vendor/cordis/src/fiber.ts `Disposable`). */
  export type Disposable = () => void

  /** Disposer of an asynchronous effect body; cordis awaits it during unload. */
  export type AsyncDisposable = () => void | Promise<void>

  /**
   * Minimal Cordis context face used by a Studio plugin. `effect` registers a
   * reversible side effect owned by the caller's fiber; the returned disposer
   * is awaitable, and cordis runs *synchronous* disposers synchronously
   * (vendor/cordis/src/fiber.ts `Fiber.effect`) — the property the manifest
   * hot-switch relies on. Both accepted shapes are transcribed: the sync one
   * carries slot registrations, the async one carries the loopback server.
   */
  export interface Context {
    effect(execute: () => Disposable, label?: string): () => Promise<void>
    effect(execute: () => Promise<AsyncDisposable>, label?: string): () => Promise<void>
  }
}

declare module '@deepseek-ai/dsh-client-ui-slots' {
  /** packages/client/ui-slots/src/index.ts — `SlotKind`. */
  export type SlotKind = 'single' | 'list' | 'keyed' | 'chain'
  /** packages/client/ui-slots/src/index.ts — `SlotScope`. */
  export type SlotScope = 'root' | 'session-maybe' | 'session'

  /**
   * packages/client/ui-slots/src/index.ts — `SlotSpec<E>` erased to its two
   * mandatory axes plus the optional slot-level inject face. This is the shape
   * a `children` table carries at runtime.
   */
  export interface SlotSpecLike {
    kind: SlotKind
    scope: SlotScope
    inject?: object
  }

  /** packages/client/ui-slots/src/index.ts — `StoredEntry`, narrowed to the inspectable members. */
  export interface StoredEntry {
    options: {
      key?: string
      id?: string
      order?: number
      priority?: number
    }
    children?: Readonly<Record<string, SlotSpecLike>> | undefined
    registrant?: string | undefined
  }

  /** packages/client/ui-slots/src/index.ts — `LiveSlotOccupant`. */
  export interface LiveSlotOccupant {
    registrant?: string
    key?: string
    id?: string
    order?: number
    priority: number
    active: boolean
  }

  /** packages/client/ui-slots/src/index.ts — `LiveSlotNode`. */
  export interface LiveSlotNode {
    name: string
    kind: SlotKind
    scope: SlotScope
    declaredBy?: string
    occupants: LiveSlotOccupant[]
    children: LiveSlotNode[]
  }
}

declare module '@deepseek-ai/dsh-client-runtime/client' {
  import type { Context, Disposable } from '@deepseek-ai/cordis'
  import type {
    LiveSlotNode, SlotSpecLike, StoredEntry,
  } from '@deepseek-ai/dsh-client-ui-slots'

  /**
   * Erased registration options — transcribed from
   * `ErasedRegisterOptions` in packages/client/runtime/src/client/slots.ts.
   * Members this package never sets (`store`, `select`, `order`, `label`) are
   * omitted rather than typed loosely.
   */
  export interface ErasedRegisterOptions {
    name: string
    children?: Record<string, SlotSpecLike>
    inject?: (...args: never[]) => Record<string, unknown>
    key?: string
    id?: string
    priority?: number
    locale?: string
    registrant?: string
  }

  /**
   * `ctx.slots` — the cordis Service layer over `SlotCore`
   * (packages/client/runtime/src/client/slots.ts). Only the members Studio
   * uses are declared; `register` is the erased face (see the file header).
   */
  export interface SlotsService {
    register(options: ErasedRegisterOptions, component: unknown): Disposable
    inject(key: string, callback: () => Disposable): Disposable
    entries(key: string): readonly StoredEntry[]
    entriesOfSlot(key: string): readonly StoredEntry[]
    spec(key: string): SlotSpecLike | undefined
    snapshot(root?: string): LiveSlotNode[]
    subscribe(key: string, fn: () => void): Disposable
    onEntryError(
      fn: (key: string, entry: StoredEntry, error: unknown, info: { abdicated: boolean }) => void,
    ): Disposable
  }

  /** Root client context (packages/client/runtime/src/client/index.ts). */
  export interface ClientContext extends Context {
    slots: SlotsService
  }

  /** Branded workspace id (packages/client/runtime/src/client/workspaces). */
  export type WorkspaceId = string & { readonly __brand: 'workspace-id' }
}

declare module '@deepseek-ai/dsh-client-ui-sidebar/client' {
  import type { WorkspaceId } from '@deepseek-ai/dsh-client-runtime/client'

  /**
   * packages/client/ui-sidebar/src/client/contract/slots.ts —
   * `SidebarSectionOwnerProps`: the owner share of `sidebar.workspaces`.
   */
  export interface SidebarSectionOwnerProps {
    wide: boolean
    expandSidebar: () => void
  }

  /** packages/client/ui-sidebar/src/client/contract/slots.ts — `SidebarSettingsOwnerProps`. */
  export interface SidebarSettingsOwnerProps {
    wide: boolean
  }

  /** packages/client/ui-sidebar/src/client/contract/slots.ts — `SidebarFooterActionOwnerProps`. */
  export interface SidebarFooterActionOwnerProps {
    wide: boolean
  }

  /** packages/client/ui-sidebar/src/client/contract/slots.ts — `SidebarRootInjected`. */
  export interface SidebarRootInjected {
    startSession: (workspaceId?: WorkspaceId) => void
    toggleSidebar: () => void
  }
}

declare module '@deepseek-ai/dsh-client-ui-workspace/client' {
  /**
   * packages/client/ui-workspace/src/client/contract/slots.ts —
   * `DirectoryFlowOwnerProps`: owner share of the two directory-flow holes,
   * one of which (`sidebar.workspaces.directoryFlow`) is the child slot the
   * official `sidebar.workspaces` occupant declares.
   */
  export interface DirectoryFlowOwnerProps {
    open: boolean
    busy: boolean
    onPicked: (path: string) => void
    onCancel: () => void
    onError: (message: string) => void
  }
}
