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
