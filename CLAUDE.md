# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Slurmy** — a native SwiftUI client for managing a [Slurm](https://slurm.schedmd.com/)
HPC cluster from iPhone, iPad and macOS. It connects to the cluster over SSH and
runs `squeue`/`sinfo`/`scontrol`/`sbatch`/`sreport`/`nvidia-smi` etc., parsing
their text output into typed models. Focus areas: job monitoring, GPU allocation
and live GPU stats, batch actions, interactive sessions, and bookmarks.

It is a SwiftUI port/derivative of the Textual TUI **slurm-tui**
(<https://github.com/ChipCracker/slurm-tui>); the TUI's panel layout, keyboard
model (`r` refresh, `n` new, `a` attach, `C` cancel, `y`/`c`/`x` sort, …) and
feature set are the design reference.

## Build & run

The project is generated with **XcodeGen** from `project.yml` — do not hand-edit
`SlurmApp.xcodeproj` (it is regenerated). After changing `project.yml` or
adding/removing files, run:

```sh
xcodegen generate
```

Build (no Apple Developer team is configured, so code signing must be disabled):

```sh
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

To actually launch on macOS, ad-hoc sign the built `.app` first (`codesign
--force --deep --sign -`). See `memory/build-run-workflow.md`.

Tests (macOS only; some require a live SSH host via `TEST_HOST` and are skipped
otherwise):

```sh
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Set `SLURMIOS_UIMOCK=1` in the environment to run the UI against mock data with
no SSH connection — useful for layout/UI work.

## Dev vs. production app

A dev build and the stable build can be installed side by side in `/Applications`
because they carry different bundle ids (defined in `project.yml` via
`configs.Debug`):

- **Debug** → `de.cwitzl.slurmapp.dev`, display name **"Slurmy Dev"**, icon
  `AppIconDev` (orange "DEV" ribbon). This is what runs when you build/run from
  Xcode, so day-to-day development never disturbs the stable app.
- **Release** → `de.cwitzl.slurmapp`, "Slurmy", icon `AppIcon`.

Distinct bundle ids mean distinct Dock entries *and* distinct Keychain
credentials. Install the latest build with:

```sh
scripts/install.sh dev    # builds Release, installs "Slurmy Dev"
scripts/install.sh prod   # builds Release, installs/refreshes "Slurmy"
```

The script always builds **Release** (a Debug build's `.debug.dylib` fails to load
once installed standalone) and signs with the stable **"Slurmy Local"** identity
so saved credentials survive rebuilds. The dev icon is generated from the
production master by `scripts/make-dev-icon.py` (Python/PIL) — re-run it (or just
`install.sh dev`) after changing `AppIcon`.

### Hot reloading (Inject)

For live development, **run from Xcode** (Debug = "Slurmy Dev") or use
`scripts/dev.sh` (`--mock` for UI-only); the installed apps from `install.sh` are
Release and do **not** hot-reload. `dev.sh` builds Debug from DerivedData with
hardened runtime off and launches it. The project wires up
[Inject](https://github.com/krzysztofzablocki/Inject): the `Inject` SPM package
(no-op in Release), `OTHER_LDFLAGS: -Xlinker -interposable` on the Debug config
only, and a `View.hotReloadable()` helper (`Theme/HotReload.swift`, wraps
`@ObserveInjection` + `.enableInjection()`) applied at `RootView`. Live swapping
also needs the external **InjectionIII** app running with this folder opened. Add
`.hotReloadable()` as the last `body` modifier of a screen for more reliable
per-screen reload. Full setup steps are in README → "Day-to-day development &
hot reloading".

## Targets & platforms

- `SlurmApp` — universal app, deployment targets **macOS 14.0** and **iOS 26.0**,
  iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), Swift 5.10.
- `SlurmAppTests` — macOS-only unit tests.
- Bundle id prefix `de.cwitzl`.

## Architecture

```
SlurmApp/
  App/          SlurmApp.swift (@main), AppState.swift (global @MainActor state)
  Models/       SlurmModels.swift (Job, Partition, GpuStat, …), Credentials.swift
  Services/     SSHClient, SlurmService, SlurmParser, *Store, KeyboardShortcuts, …
  Theme/        Theme.swift (colors/glass), PlatformExtensions.swift (#if os modifiers)
  Views/        RootView, MainTabView, JobsView, JobDetailView, Settings…, modals, components
  Resources/    Assets.xcassets
Vendor/         Shout (SSH), libssh2.xcframework, openssl.xcframework
```

**Data / connection flow**

- `AppState` (@MainActor, `@EnvironmentObject`) owns `credentials` (Keychain-backed),
  `connectionStatus`, and the live `SlurmService?`. It auto-connects on launch if
  credentials exist.
- `RootView` routes on `connectionStatus`: connected → `MainTabView`,
  connecting → loading, else → `ConnectionSetupView`.
- `MainTabView` is platform-split: macOS `NavigationSplitView` (sidebar + detail),
  iOS `TabView`. Sections: Jobs / Bookmarks / Settings.
- `SSHClient` (serializes all calls on one queue — libssh2 is not thread-safe) →
  `SlurmService` (`actor`) → `SlurmParser` (pure parsing, unit-tested).
- View models `JobsViewModel` / `JobDetailViewModel` are `@MainActor final class`
  observables; they poll (jobs ~10s, GPU stats ~5s).

**Read-only safety**: `SSHClient.execute` is guarded by a whitelist
(`ReadOnlyGuard`) that only permits known-safe read commands and rejects
redirections/unsafe pipes. Mutating commands (scancel, scontrol update, sbatch,
hold/release/requeue) go through `executeWrite`, called only from explicit
user actions.

## Conventions

- **UI text is German** (labels, captions); code identifiers and comments are a
  mix of English and German — match the surrounding file.
- **Platform differences** live in `PlatformExtensions.swift` and `#if os(macOS)`
  / `#if os(iOS)` blocks. macOS gets split views, hover, full keyboard nav;
  iOS gets sheets, swipe actions, touch targets.
- **Keyboard shortcuts** have a single source of truth: the `Shortcut` enum in
  `Services/KeyboardShortcuts.swift`. Add bindings there so the help overlay
  (`HelpOverlayView`, driven by `Shortcut.helpRows()`) stays in sync. Use
  `Shortcut.hiddenButton()` to wire keys.
- **Styling** goes through `Theme` (semantic colors, `stateColor`, `qosColor`,
  `utilizationColor`) and `GlassPanel` / `.glassModal(…)` for frosted overlays.
  Prefer these over ad-hoc colors/materials.
- **Liquid Glass**: all glass rendering funnels through `Theme/LiquidGlass.swift`
  (`.slurmyGlass(…)`, `.slurmyGlassButton(…)`, `SlurmyGlassButtonGroup`) —
  native `glassEffect` on macOS 26+/iOS 26, legacy frost fallback on macOS 14/15
  (every SDK-26 API needs `if #available(macOS 26.0, *)`). HIG discipline:
  glass only on the floating layer (modals, overlays, header buttons), never on
  content cards and never glass-on-glass (`GlassPanel` sets the
  `insideGlassPanel` environment flag so nested controls de-glass themselves).
- **Persistence**: Keychain (credentials), `~/Documents/bookmarks.json`
  (bookmarks), `@AppStorage`/UserDefaults (preferences like `appearance`,
  `accentTheme`, `textSizeIndex`, `inspectorOpen`).

## Gotchas

- Regenerate with `xcodegen generate` after touching `project.yml`; don't commit
  manual `.xcodeproj` edits.
- Code signing is off by default (no team) — always pass `CODE_SIGNING_ALLOWED=NO`
  to `xcodebuild`, and ad-hoc sign before running.
- `SlurmService` is an `actor` — `await` its calls; never touch SSH off its queue.
- When adding Slurm features, parse in `SlurmParser` and cover it with a fixture
  in `SlurmAppTests/Fixtures/` + a `SlurmParserTests` case.
