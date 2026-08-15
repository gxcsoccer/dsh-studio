# Theming

DSH Studio skins the native chrome — and, when the official Web UI is loaded in WKWebView, the page — from **semantic token packs**. Packs never name a control. They name roles.

Canonical packs live in [`themes/`](../themes/). Copies ship inside `plugin/themes/` and `app/Sources/DSH/Resources/Themes/` so each layer can load them alone.

## Schema

A pack is JSON:

```json
{
  "id": "studio-dark",
  "name": "Studio Dark",
  "nameZh": "Studio 深色",
  "appearance": "dark",
  "tokens": { }
}
```

`appearance` is `light`, `dark`, or `system`. A `system` pack stores both sides instead of a single `tokens` object:

```json
{
  "id": "system",
  "appearance": "system",
  "light": { },
  "dark": { }
}
```

### Semantic tokens (only these)

| Token | Role |
| --- | --- |
| `background` | Window / page ground |
| `surface` | Sidebar, status, inset panels |
| `elevated` | Popovers, command palette, cards |
| `text.primary` / `secondary` / `tertiary` | Copy hierarchy |
| `border.subtle` / `strong` | Hairline vs. emphasis |
| `accent` | The one brand color |
| `danger` / `warning` / `success` | Status (always paired with text or an icon) |
| `overlay` | Dim behind modal / palette |
| `focusRing` | Keyboard focus |
| `radius` | `sm` `md` `lg` `xl` (px) |
| `space` | `1`…`8` scale (px) |
| `type` | `xs` `sm` `md` `lg` `xl` `display` (px) |
| `shadow` | `sm` `md` `lg` (CSS shadow strings) |
| `motion` | `fast` `normal` `slow` (ms) |

No gradients. No per-component colors. One accent.

## CSS variables (WKWebView injection)

The bridge (`GET /theme`) and the Swift host both emit the same mapping:

| Token | CSS custom property |
| --- | --- |
| `background` | `--dsh-background` |
| `surface` | `--dsh-surface` |
| `elevated` | `--dsh-elevated` |
| `text.primary` | `--dsh-text-primary` |
| `text.secondary` | `--dsh-text-secondary` |
| `text.tertiary` | `--dsh-text-tertiary` |
| `border.subtle` | `--dsh-border-subtle` |
| `border.strong` | `--dsh-border-strong` |
| `accent` | `--dsh-accent` |
| `danger` | `--dsh-danger` |
| `warning` | `--dsh-warning` |
| `success` | `--dsh-success` |
| `overlay` | `--dsh-overlay` |
| `focusRing` | `--dsh-focus-ring` |
| `radius.*` | `--dsh-radius-*` |
| `space.*` | `--dsh-space-*` |
| `type.*` | `--dsh-type-*` |
| `shadow.*` | `--dsh-shadow-*` |
| `motion.*` | `--dsh-motion-*` |

The host injects a `:root` stylesheet at document start and again on hot-swap. Official Web UI variables are not assumed; the injection sets Studio tokens. A third-party page can read `--dsh-*` if it wants to match.

## Drop a third-party skin into the profile

1. Copy a pack (start from `themes/studio-dark.json`).
2. Change `id` and `name`. Keep the token keys. Put the file in one of:
   - the checkout `themes/` folder (dev)
   - `plugin/themes/` next to the installed bundle
   - `~/Library/Application Support/DSHStudio/themes/` (host also searches here)
3. Restart the runtime, or `POST /theme` with `{ "themeId": "your-id" }`.
4. In Settings, pick the pack. Accent / density / type scale stay host preferences and do not rewrite the file.

The native host never hardcodes product colors. If a token is missing, the active pack’s fallback (Studio Dark or Light) fills that slot.

Hot-swap from the host: `POST http://127.0.0.1:43180/theme` with `{ "themeId", "appearance?", "tokens?" }`. `tokens` overlays the current pack for a live accent tweak without writing a file.
