# Slurm — iOS & macOS

Native SwiftUI app for **iPhone, iPad and Mac** (no Catalyst — a native macOS
target) that exposes the features of [`slurm-tui`](../slurm-tui) over an SSH
connection to the kiz0 login node.

Tokyo Night theme, pull-to-refresh, job list with filtering & sorting, GPU
allocation overview, partition details, batch-script and log viewer, bookmarks,
and multi-selection with batch actions (cancel, QoS/partition update,
hold/release/requeue). A read-only layer is active by default; mutating commands
(sbatch, scancel, scontrol update) go explicitly through `executeWrite`.

## Setup

```bash
git clone git@github.com:ChipCracker/slurm-app.git
cd slurm-app

# 1) Build the SSH stack (OpenSSL + libssh2) as xcframeworks — ONE-TIME; the
#    results are checked into Vendor/. Required because libssh2 cannot come from
#    Homebrew on iOS. Default: arm64 slices; universal with BUILD_X86_64=1.
./scripts/build-libssh2-xcframework.sh         # produces Vendor/{openssl,libssh2}.xcframework

# 2) Generate the Xcode project (XcodeGen: `brew install xcodegen`)
xcodegen generate

# 3) Resolve dependencies (local Shout fork + BlueSocket)
xcodebuild -resolvePackageDependencies -project SlurmApp.xcodeproj -scheme SlurmApp

# Open in Xcode
open SlurmApp.xcodeproj
```

> The SSH stack uses **libssh2** (not Citadel): a local Shout fork (`Vendor/Shout`)
> links against the prebuilt `Vendor/*.xcframework` instead of Homebrew's
> `systemLibrary`. That way the same code builds for macOS **and** iOS (device +
> simulator). See [`scripts/build-libssh2-xcframework.sh`](scripts/build-libssh2-xcframework.sh).

## Build & Run

### iOS Simulator

```bash
SIM_ID=$(xcrun simctl list devices available | grep "iPhone 17 (" | head -1 | grep -oE "[0-9A-F-]{36}")

xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath build build

xcrun simctl boot "$SIM_ID" || true
xcrun simctl install "$SIM_ID" build/Build/Products/Debug-iphonesimulator/SlurmApp.app
xcrun simctl launch "$SIM_ID" de.cwitzl.slurmapp
```

### macOS (native)

```bash
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

open build/Build/Products/Debug/SlurmApp.app
```

On the Mac the app runs with a native **NavigationSplitView sidebar**, on
iPhone/iPad with a TabView. Same source tree; the differences live in
`MainTabView.swift` behind `#if os(macOS)`.

## Installing into /Applications (dev & prod side by side)

`scripts/install.sh` builds, signs and drops a standalone app into
`/Applications` so the latest build is one click away in the Dock. Two flavours
coexist — distinct bundle ids → separate Dock entries **and** separate Keychain
credentials, so a dev build never disturbs your daily driver:

```bash
scripts/install.sh prod   # → "Slurmy"      (de.cwitzl.slurmapp)      production icon
scripts/install.sh dev    # → "Slurmy Dev"  (de.cwitzl.slurmapp.dev)  orange DEV-ribbon icon
```

The script always builds the **Release** configuration (even for `dev`) and signs
with the stable "Slurmy Local" identity. Release is required because a Debug build
wraps a separate `.debug.dylib` that fails to load once installed standalone; the
stable identity keeps saved credentials across rebuilds. The two installed apps
are just for **coexistence** — neither has hot reloading (that needs running from
Xcode, see below).

## Day-to-day development & hot reloading

For actual development, **run from Xcode** (⌘R), or use the one-command launcher:

```bash
scripts/dev.sh            # build Debug + launch "Slurmy Dev", real cluster
scripts/dev.sh --mock     # same, with mock data (SLURMIOS_UIMOCK=1), no SSH
```

Either way the Debug configuration builds as **"Slurmy Dev"**
(`de.cwitzl.slurmapp.dev`, orange DEV icon, own Keychain), so it never clobbers
the installed stable app. `dev.sh` builds straight from DerivedData with hardened
runtime off (so injection can load) and signs with "Slurmy Local" so credentials
persist — keep it running and re-save files to hot-reload.

SwiftUI has no built-in hot reload, so the project wires up
[**Inject**](https://github.com/krzysztofzablocki/Inject): save a file in Xcode
and the running app swaps the method bodies live — no rebuild, no restart, state
preserved. One-time setup:

1. **Install the InjectionIII helper app** — from the
   [Mac App Store](https://apps.apple.com/app/injectioniii/id1380446739) (easiest,
   no Gatekeeper friction) or the
   [GitHub releases](https://github.com/johnno1962/InjectionIII/releases).
2. **Launch InjectionIII** and via **File → Open…** select this repo's **folder**
   (not the `.xcodeproj`); it then watches the sources for changes.
3. **Run the app** — from Xcode (Debug) or via `scripts/dev.sh`. On launch the
   console prints `💉 Injection connected` once InjectionIII has hooked in.
4. **Edit a view, hit ⌘S** — the change appears in the running app instantly.

How it's wired (already done, nothing to configure):

- The `Inject` SPM package is a dependency (`project.yml`). It compiles to a
  **no-op in Release** — zero runtime cost in the shipped app.
- The Debug config carries `OTHER_LDFLAGS: -Xlinker -interposable`, which lets
  Inject interpose and swap symbols. Release does **not** get this flag.
- The Debug config also sets `EMIT_FRONTEND_COMMAND_LINES: YES` — **required on
  Xcode 16.3+ (incl. Xcode 26)** so InjectionIII can locate compile commands;
  without it injection fails with "Could not locate compile command".
- `View.hotReloadable()` (in `Theme/HotReload.swift`) bundles
  `@ObserveInjection` + `.enableInjection()`. It's applied at `RootView`, which
  re-renders the whole tree on each injection. To make a specific screen reload
  more reliably, add `.hotReloadable()` as the **last** modifier of its `body`.

## Tests

```bash
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build test
```

Currently: 20 unit tests pass (parser, read-only guard, usage aggregation,
array-job-ID normalization). Three SSH integration tests run against a real
cluster and are skipped without credentials (23 tests total).

### Enabling the integration tests against kiz0

The tests read credentials from environment variables. Since `xcodebuild test`
does **not** forward env vars to the simulator, the simplest options are an
xctestplan or setting the variables in the scheme. Alternatively, run directly
via `xcrun simctl spawn …` with the env vars set.

Variables:
- `SLURMIOS_SSH_HOST` (e.g. `kiz0.in.ohmportal.de`)
- `SLURMIOS_SSH_USER`
- `SLURMIOS_SSH_PASSWORD` **or** `SLURMIOS_SSH_KEY` (PEM contents, optionally
  `SLURMIOS_SSH_PASSPHRASE`)

The tests run **read-only** commands only (`echo`, `hostname`, `squeue`) and do
not change cluster state.

## Features (TUI parity)

| TUI | App |
|---|---|
| GPU allocation monitor | Cluster inspector (10s auto-refresh) |
| Job list, sorting, filtering | `JobsView` (sortable, searchable, 10s auto-refresh) |
| Job details incl. script & logs | `JobDetailView` (script via `scontrol write batch_script`, logs via `tail`) |
| Partition details | `PartitionSheetView` |
| Bookmarks | `BookmarksView` (stored locally in `Documents/bookmarks.json`) |
| Cancel job | `scancel` with confirmation dialog |
| Multi-selection + batch actions | cancel, QoS/partition update, hold/release/requeue (per-job loop) |
| Job submission | `SubmitJobView` → `sbatch` |
| Interactive sessions | macOS only (delegated to Terminal.app via `srun --pty`) |
| Terminal/Attach | omitted on iOS (no PTY surface) |
| Live nvidia-smi on compute node | currently only login-node aggregate via sinfo + squeue |

## Read-only guarantee

`SSHClient.execute(_:)` only lets whitelisted commands through:

```
echo  hostname  whoami  cat  tail  head  ls  stat  wc  grep  awk
sort  uniq  tr  cut  sed
squeue  sinfo  sacct  sreport
sacctmgr show       scontrol show       scontrol write batch_script
nvidia-smi --query  nvidia-smi -q
```

Mutating commands (`sbatch`, `scancel`, `scontrol update`, `srun`, etc.) run
exclusively through `SSHClient.executeWrite(_:)` and are only fired from the UI
after explicit user confirmation. Shell redirections (`>`, `<`) are hard-blocked
by the guard. `ReadOnlyGuardTests` pins this behavior.

## Project layout

```
slurm-app/
├── project.yml                       # xcodegen
├── scripts/
│   └── build-libssh2-xcframework.sh  # builds Vendor/*.xcframework
├── Vendor/
│   ├── Shout/                        # local Shout fork (libssh2 wrapper)
│   ├── libssh2.xcframework
│   └── openssl.xcframework
├── SlurmApp/
│   ├── App/
│   │   ├── SlurmApp.swift
│   │   └── AppState.swift
│   ├── Models/
│   │   ├── Credentials.swift
│   │   └── SlurmModels.swift         # Job, Partition, JobDetails, GpuStat, Bookmark
│   ├── Services/
│   │   ├── SSHClient.swift           # Shout/libssh2 wrapper + ReadOnlyGuard
│   │   ├── SlurmService.swift        # squeue/sinfo/scontrol/tail logic
│   │   ├── SlurmParser.swift         # stringly typed → domain models
│   │   ├── KeychainStore.swift       # credentials → Keychain
│   │   └── BookmarksStore.swift
│   ├── Theme/Theme.swift             # Tokyo Night palette + CardStyle
│   ├── Views/                        # JobsView, JobDetailView, BatchActions, …
│   ├── Resources/Assets.xcassets/
│   └── Info.plist
└── SlurmAppTests/
    ├── SlurmParserTests.swift
    ├── ReadOnlyGuardTests.swift
    ├── SSHIntegrationTests.swift
    └── Fixtures/                     # real squeue/sinfo/scontrol output from kiz0
```

## Dependencies

- **libssh2 1.11.x** + **OpenSSL 3.x** — built from source into static
  `Vendor/*.xcframework`s (`scripts/build-libssh2-xcframework.sh`), with slices
  for `macos-arm64_x86_64`, `ios-arm64` (device) and
  `ios-arm64_x86_64-simulator`. OpenSSL is the crypto backend so that libssh2
  supports the algorithms kiz0 (OpenSSH 9.x) uses (curve25519-sha256,
  aes-ctr/gcm, ssh-ed25519 host keys, rsa-sha2-256/512).
- [Shout](https://github.com/jakeheis/Shout) (MIT) — forked locally into
  `Vendor/Shout`: a libssh2 wrapper whose `CSSH` module now comes from the
  xcframework instead of Homebrew.
- [BlueSocket](https://github.com/IBM-Swift/BlueSocket) 1.0.x — TCP sockets
  (a Shout dependency, builds for iOS as well as macOS).

## License

MIT
