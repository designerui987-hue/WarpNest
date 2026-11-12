# WarpNest Implementation & Verification Progress

## Milestone Status

### Milestone 1: Environment & Architecture Foundation
- [x] Host architecture audited (macOS 27.2 arm64, Apple Silicon, Rosetta 2 translation layer verified).
- [x] Swift package and Xcode workspace structure initialized with Swift 6 and strict concurrency checking.
- [x] CI workflow updated for Xcode 16 / Swift 6 toolchain on macOS 14 runners.

### Milestone 2: Core Domain & Safe Supervision
- [x] `ProcessSupervisor`: Supervised async process launcher executing without shell interpolation. Concurrently drains stdout/stderr byte lines into a bounded `LogRingBuffer`.
- [x] `MetadataStore`: Atomic filesystem persistence using temporary file writing followed by atomic file swapping (`.replaceItemAt`).
- [x] `BottleService`: Actor managing bottle lifecycles. Implements mutex locks preventing operations during active game sessions.
- [x] `LibraryService`: Actor decoupling game shortcut catalog from physical bottle life cycles. Publishes lifecycle transitions (`preparing`, `running`, `stopping`, `stopped`, `failed`).

### Milestone 3: Hardening & Bug Fixes (Source Review Addressed)
- [x] **Explicit Simulation Mode**: `TestRuntimeAdapter` tagged with `isSimulation: true` and moved behind an explicit developer setting. Never substituted silently for Wine.
- [x] **Lazy Runtime Validation**: `WineRuntimeAdapter` starts with `isVerified = false`. Performs real `wine --version` execution with bounded timeout to query actual version string.
- [x] **Runtime Import & Selection**: Dedicated UI in Settings and Bottle Creation to import and select among verified runtimes.
- [x] **Shared Bottle Locking**: Launching a game acquires bottle locks. `deleteBottle` and `backupBottle` fail safely with `BottleBusy` error if a session is running.
- [x] **Archive & Traversal Safeguards**: Bottle backup preserves symlinks (`-y`); restore inspects archive contents via `zipinfo` to reject path traversal (`../`) and unmapped links.
- [x] **Settings Persistence**: `AppSettings` model persisted to `settings.json`.

### Milestone 4: End-to-End Windows Demonstration
- [x] Simulated end-to-end integration test (`BottleAndLibraryTests.testEndToEndWorkflow`): Passed.
- [ ] **Live Windows GUI App Launch on Host**: Blocked pending availability of a real Wine runtime on the host machine. Exhaustive search across `/Applications`, `/opt`, `/usr/local`, and user home confirmed `wine` is not pre-installed. The runtime import UI and validation logic are ready for use once a runtime bundle is provided.
