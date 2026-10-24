# CodeRabbit full-codebase review brief

Hello @coderabbitai — this PR targets `main` and is intended to merge.
It adds `.coderabbit.yaml` and this brief (no Swift changes), so the
config governs every future PR. Please review the config/brief here.
Assess all Swift sources and tests at the current PR head, using its
merge base with the base branch to identify changes.

> Swift fixes arising from this review will land on `main` in small
> follow-up PRs, each with its own inline CodeRabbit review.

App in one line: a native Swift/AppKit menu-bar window manager for
macOS 14+ using the Accessibility (AX) API — no network, no account,
`ENABLE_APP_SANDBOX: NO`, no kernel extension, no SIP changes.

Key files: `Models/StableLayout.swift` (pure halves/quarters planner +
`AppClassifier`), `Models/LayoutTree.swift` (BSP + Master/Columns/Grid),
`Services/AXWindowService.swift` (AX enumeration/frame set),
`Services/TilingManager.swift` (@MainActor orchestrator, per-display
state, fingerprint no-ops, 360 ms animation), `Services/DragDockMonitor.swift`,
`Services/HotkeyManager.swift`, `AppDelegate.swift` (menu bar,
`NSWorkspace` observers). Tests: `Tests/MacOSWindowsManagerTests/`.

Please structure the review around the four questions below. For each
finding: file + symbol, severity, concrete failure/cost, smallest safe
fix (Swift snippet welcome). Prefer incremental fixes over rewrites.

## 1. Rational layout: at most ~4–5 apps per monitor, app-type aware

Current behaviour (please verify, don't assume): per display,
`StableLayout.maxVisible` returns 4, 2, or 1; layouts are full /
halves / half + two quarters / four quarters; a quarter smaller than
~440×300 pt is never produced; window 5+ tabs behind a similar app's
tile and is promoted when a slot frees; survivors never shuffle on
focus clicks (window-set fingerprint + stable order, primary never
moves, at most one pairing swap).

Review asks:

- Is "max 4 visible, 5th always tabbed" the right rationality cap for
  every display, or should very large/ultrawide/portrait displays
  rationally show 5 — and if so, in exactly which geometry (e.g.
  half + 4 stacked quarters, 5 columns ≥ minimum width)? Define the
  rule in terms of minimum readable tile size, not raw window count.
- `AppClassifier` knows app type (browser, messaging, mail, code,
  terminal, documents, media, meetings) but `slotRects` ignores it.
  Propose app-type-aware slot assignment: portrait-preferring apps
  (messaging/documents/terminal/mail) get tall/narrow slots,
  landscape-preferring apps (browser/code/media/meetings) get wide
  slots — on landscape *and* portrait monitors — without violating
  the no-churn stability contract or the minimum-tile rule.
- Audit every layout mode (Stable, BSP, Master+Stack, Columns, Grid)
  for sliver tiles, seam clamps, and behaviour at exactly 4, 5, 6+
  windows on small (13"), large (5K/ultrawide), and portrait displays.

## 2. Works across additional virtual desktops (macOS Spaces)

Current behaviour: only windows on the current Space are arranged;
tiling suspends during Mission Control/Exposé;
`activeSpaceDidChangeNotification` adopts the arrived Space's windows
as-is; all planner state (`trees`, `cameras`, `stableOrder`,
saved views) is keyed by display only.

Review asks:

- What breaks, leaks, or cross-contaminates today when the user keeps
  different window sets on several Spaces per display, moves a window
  between Spaces, or uses fullscreen-app Spaces?
- Design the smallest **public-API-only** extension for independent,
  stable layouts per (display × Space): how to key state without a
  public Space ID, when to snapshot/restore, how saved views should
  scope, and how to keep "looking around never rearranges anything."
  Explicitly flag any step that would require private CGS/SkyLight
  APIs and give the safe degraded alternative instead.

## 3. Must never cause kernel panics or destabilise the system

Please be precise: this is a user-space app (AppKit + AX + Carbon
hotkeys + `NSEvent` monitors + one private symbol,
`_AXUIElementGetWindow` via `@_silgen_name` in `AXWindowService`).
There is no kext/driver/daemon code to panic the kernel directly.

Review asks:

- Confirm or refute: no code path can panic the kernel. If you claim
  any system-stability risk, name the exact mechanism (e.g. an
  unthrottled `AXUIElementSetAttributeValue` storm against
  WindowServer) with file/symbol — otherwise classify risks honestly
  as app crash / WindowServer load / hung target app.
- Audit all crash surfaces: force unwraps/casts, CF type punning,
  `AXValueCreate`/`AXUIElementCopyMultipleAttributeValues` handling,
  recursion depth in `LayoutTree`, geometry overflow, and behaviour
  when a target app is hung, quits mid-retile, or denies AX access.
- Check failure containment: a hung/misbehaving app, a display
  hot-unplug mid-animation, or revoked Accessibility permission must
  degrade to "do nothing," never to a retry loop or partial smash.

## 4. Efficient and clean: ~zero cost when idle

Review asks:

- Idle cost: enumerate every `Timer`, `Task.sleep` loop, `NSEvent`
  global monitor, `NSWorkspace` observer, and AX enumeration. Which
  fire when nothing changed? (Known suspects to verify: 2 s trust
  timer in `AppDelegate`, animation pacing and Mission Control waits
  in `TilingManager`, per-event work in `DragDockMonitor`.) The bar:
  no polling, no repeated full AX enumerations, fingerprint no-ops
  stay no-ops.
- Active cost: complexity of `StableLayout.plan`, `syncTree`,
  `groupByDisplay`, `fingerprint` as window/display counts grow;
  allocations per retile; redundant `allWindows()` calls (e.g. the
  `originalFrames` prune path); `@MainActor` blocking.
- Memory/state hygiene: unbounded growth (`originalFrames`, trees,
  cameras, saved views), stale display/Space keys after hot-plug,
  retain cycles, missing teardown (`removeMonitor`, hotkey
  unregistration, timer invalidation), and `UserDefaults` write cost.
- Cleanliness: dead code, Models↔Services boundary violations
  (Models must stay pure/testable), duplicated geometry logic, and
  the highest-value missing unit tests for §§1–2 (boundary sizes
  around 440×300, 5+ overflow promotion order, portrait stacks,
  3+ display assignment, per-Space isolation).

## Output requested

@coderabbitai full review

Please give: (a) a prioritised findings list (P0 stability/resource
risks first), (b) a direct answer to each of §§1–4 including the
kernel-panic verdict, and (c) a short, ordered "fix first" plan of
small follow-up PRs. Inline comments on the relevant lines, please.
