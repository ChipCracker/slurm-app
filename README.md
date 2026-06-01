# Slurm — iOS & macOS

Native SwiftUI-App für **iPhone, iPad und Mac** (kein Catalyst — natives
macOS-Target), die die Funktionen von [`slurm-tui`](../slurm-tui) über eine
SSH-Verbindung zum kiz0-Login-Node bereitstellt.

Tokyo-Night-Theme, Pull-to-Refresh, Job-Liste mit Filter & Sortierung,
GPU-Allocation-Übersicht, Partition-Details, Batch-Skript- und Log-Anzeige,
Bookmarks. Read-only-Schicht standardmäßig aktiv, Mutationen (sbatch,
scancel, scontrol update) gehen explizit über `executeWrite`.

## Setup

```bash
cd ~/Documents/Entwicklung/slurm-ios

# 1) SSH-Stack (OpenSSL + libssh2) als xcframeworks bauen — EINMALIG, danach
#    in Vendor/ eingecheckt. Nötig, weil libssh2 auf iOS nicht aus Homebrew
#    kommen kann. Default: arm64-Slices; universell mit BUILD_X86_64=1.
./scripts/build-libssh2-xcframework.sh         # erzeugt Vendor/{openssl,libssh2}.xcframework

# 2) Xcode-Projekt generieren (XcodeGen: `brew install xcodegen`)
xcodegen generate

# 3) Dependencies (lokaler Shout-Fork + BlueSocket) auflösen
xcodebuild -resolvePackageDependencies -project SlurmApp.xcodeproj -scheme SlurmApp

# In Xcode öffnen
open SlurmApp.xcodeproj
```

> Der SSH-Stack nutzt **libssh2** (nicht Citadel): ein lokaler Shout-Fork
> (`Vendor/Shout`) linkt statt der Homebrew-`systemLibrary` gegen die
> vorgebauten `Vendor/*.xcframework`. So baut derselbe Code für macOS **und**
> iOS (Device + Simulator). Details siehe
> [`scripts/build-libssh2-xcframework.sh`](scripts/build-libssh2-xcframework.sh).

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

### macOS (nativ)

```bash
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

open build/Build/Products/Debug/SlurmApp.app
```

Auf Mac läuft die App mit nativer **NavigationSplitView-Sidebar**, auf iPhone/iPad
mit TabView. Gleicher Source-Tree, Unterschiede in `MainTabView.swift` per
`#if os(macOS)`.

## Tests

```bash
xcodebuild -project SlurmApp.xcodeproj -scheme SlurmApp \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath build test
```

Aktuell: 18 Unit-Tests grün (Parser, Read-Only-Guard, Usage-Aggregation,
Array-Job-ID-Normalisierung). Drei SSH-Integration-Tests laufen gegen ein
echtes Cluster und werden ohne Credentials übersprungen.

### Integration-Tests gegen kiz0 aktivieren

Die Tests lesen Credentials aus Env-Vars. Da `xcodebuild test` Env-Vars
**nicht** an den Simulator durchreicht, ist der einfachste Weg ein
xctestplan oder das Setzen der Variablen im Scheme. Alternativ direkt
über `xcrun simctl spawn …` mit gesetzten Env-Vars.

Variablen:
- `SLURMIOS_SSH_HOST` (z. B. `kiz0.in.ohmportal.de`)
- `SLURMIOS_SSH_USER`
- `SLURMIOS_SSH_PASSWORD` **oder** `SLURMIOS_SSH_KEY` (PEM-Inhalt, optional
  `SLURMIOS_SSH_PASSPHRASE`)

Die Tests führen ausschließlich **read-only** Befehle aus (`echo`,
`hostname`, `squeue`) und greifen nicht in den Cluster-Zustand ein.

## Features (TUI-Parität)

| TUI | iOS-App |
|---|---|
| GPU Allocation Monitor | `GpuMonitorView` (10s Auto-Refresh) |
| Job-Liste, Sortierung, Filter | `JobsView` (sortable, searchable, 10s Auto-Refresh) |
| Job-Details inkl. Skript & Logs | `JobDetailView` (Skript via `scontrol write batch_script`, Logs via `tail`) |
| Partition-Details | `PartitionsView` → `PartitionDetailView` |
| Bookmarks | `BookmarksView` (lokal in `Documents/bookmarks.json`) |
| Job-Cancel | `JobDetailView` → `scancel` mit Bestätigungsdialog |
| Job-Submission, Interactive Sessions | Geplant — `SlurmService.submitScript` ist verdrahtet, UI dafür folgt |
| Terminal/Attach | Auf iOS nicht sinnvoll, weggelassen |
| Live nvidia-smi auf Compute-Node | Aktuell nur Login-Node-Aggregat via sinfo + squeue |

## Read-Only-Garantie

`SSHClient.execute(_:)` lässt nur whitelisted Befehle durch:

```
echo  hostname  whoami  cat  tail  head  ls  stat  wc  grep  awk
sort  uniq  tr  cut  sed
squeue  sinfo  sacct  sreport
sacctmgr show       scontrol show       scontrol write batch_script
nvidia-smi --query  nvidia-smi -q
```

Mutierende Befehle (`sbatch`, `scancel`, `scontrol update`, `srun`, etc.)
laufen ausschließlich über `SSHClient.executeWrite(_:)` und werden im UI
nur nach expliziter Nutzer-Bestätigung gefeuert. Shell-Redirections (`>`,
`<`) sind im Guard hart verboten. Tests in `ReadOnlyGuardTests` halten das
Verhalten fest.

## Projektstruktur

```
slurm-ios/
├── project.yml                       # xcodegen
├── SlurmApp/
│   ├── App/
│   │   ├── SlurmApp.swift
│   │   └── AppState.swift
│   ├── Models/
│   │   ├── Credentials.swift
│   │   └── SlurmModels.swift         # Job, Partition, JobDetails, GpuStat, Bookmark
│   ├── Services/
│   │   ├── SSHClient.swift           # Shout/libssh2-Wrapper + ReadOnlyGuard
│   │   ├── SlurmService.swift        # squeue/sinfo/scontrol/tail Logik
│   │   ├── SlurmParser.swift         # Stringly typed → Domain Models
│   │   ├── KeychainStore.swift       # Credentials → iOS Keychain
│   │   └── BookmarksStore.swift
│   ├── Theme/Theme.swift             # Tokyo-Night-Palette + CardStyle
│   ├── Views/
│   │   ├── RootView.swift
│   │   ├── ConnectionSetupView.swift # Erstkonfiguration + Connection-Test
│   │   ├── MainTabView.swift
│   │   ├── JobsView.swift
│   │   ├── JobDetailView.swift
│   │   ├── GpuMonitorView.swift
│   │   ├── PartitionsView.swift
│   │   ├── BookmarksView.swift
│   │   └── SettingsView.swift        # Connection-Status + SSH-Ping
│   ├── Resources/Assets.xcassets/
│   └── Info.plist
└── SlurmAppTests/
    ├── SlurmParserTests.swift
    ├── ReadOnlyGuardTests.swift
    ├── SSHIntegrationTests.swift
    └── Fixtures/                     # echte squeue/sinfo/scontrol Outputs von kiz0
```

## Dependencies

- **libssh2 1.11.x** + **OpenSSL 3.x** — als statische `Vendor/*.xcframework`
  selbst gebaut (`scripts/build-libssh2-xcframework.sh`), Slices für
  `macos-arm64_x86_64`, `ios-arm64` (Device) und `ios-arm64_x86_64-simulator`.
  OpenSSL als Krypto-Backend, damit libssh2 die von kiz0 (OpenSSH 9.x) genutzten
  Verfahren beherrscht (curve25519-sha256, aes-ctr/gcm, ssh-ed25519-Hostkeys,
  rsa-sha2-256/512).
- [Shout](https://github.com/jakeheis/Shout) (MIT) — lokal geforkt nach
  `Vendor/Shout`: libssh2-Wrapper, dessen `CSSH`-Modul jetzt aus dem xcframework
  statt aus Homebrew kommt.
- [BlueSocket](https://github.com/IBM-Swift/BlueSocket) 1.0.x — TCP-Sockets
  (Shout-Abhängigkeit, baut für iOS wie macOS).

## Lizenz

MIT
