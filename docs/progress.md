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

### Milestone 4: QA Review & Security Hardening (WN-01 through WN-15)
- [x] **WN-01 / WN-12**: Executable path/cwd resolution, canonical validation, typed external installer paths, and WINEPREFIX protection.
- [x] **WN-02**: Non-blocking concurrent pipe draining for `zip`, `zipinfo`, and `unzip`, eliminating deadlocks on large file collections.
- [x] **WN-03**: Persisted runtime registry with stable collision-free IDs (`runtimes.json`), rehydration on cold start, and missing runtime handling.
- [x] **WN-04**: Bounded process supervision, byte-limited log ring buffer (1 MB max), and process group safe kill.
- [x] **WN-05**: Per-launch session IDs, `BottleLockLease` tokens, atomic reservation with failure rollback, and obsolete callback protection.
- [x] **WN-06**: Shared application-scoped service container across all SwiftUI windows (`MainWindowView(viewModel: sharedViewModel)`).
- [x] **WN-07**: Archive security: escaping symlink target inspection, traversal rejection, and Wine prefix structure validation.
- [x] **WN-08**: Staged atomic backup replacement (`.staging_*.zip`) and honest filesystem error propagation during bottle deletion.
- [x] **WN-09**: Clean unregistration of `TestRuntimeAdapter` when Developer Mode is disabled, and visual simulation badges.
- [x] **WN-10**: Authoritative session state transitions (only mark `.running` after spawn succeeds) and live log streaming.
- [x] **WN-11**: Bottle creation form uses persisted default sync backend.
- [x] **WN-13**: Replaced mock tests with 19 comprehensive native tests in 4 suites using real archive fixtures (`../evil.txt`, symlinks), Unicode/spaces, and byte retention.
- [x] **WN-14**: Development build designated as `0.2.0-alpha` targeting Apple Silicon ARM64; Intel support marked pending physical hardware test.
- [x] **WN-15**: Backward-compatible decoding for legacy `d3dMetal` settings to `.dxvk`, corrupt metadata backup preservation, and dynamic architecture detection.

### Milestone 5: End-to-End Windows Demonstration & Qualification
- [x] Simulated end-to-end integration test (`BottleAndLibraryTests.testEndToEndWorkflow`): Passed.
- [x] **Live Windows GUI App Launch on Host**: Verified and passed via `RealWineRuntimeDemonstrationTests`. Downloaded and extracted Wine-Staging 11.21 (`wine-staging-11.21-osx64.tar.xz`), validated runtime (`wine-11.21 (Staging)`), created real prefix with `wineboot -u`, launched and supervised Windows Notepad (`drive_c/windows/notepad.exe`), verified exclusive session locking, stopped prefix cleanly with `wineserver -k`, and verified lock release.
- [x] **Restart & Relaunch Verification (`testRealWineRestartAndRelaunch`)**: Rehydrated runtime registry from `runtimes.json` on a clean service instance, reloaded bottle and game metadata, relaunched `notepad.exe` under supervised lease, verified locks and stopped cleanly.
- [x] **Windows GUI Game Qualification (`testRealWineGameQualification`)**: Qualified Windows GUI game (`winemine.exe`) under Wine-Staging 11.21 on Apple Silicon host with MoltenVK Vulkan 1.4.323 and GDI graphics, session supervision, log streaming, and exclusive lock protection.
- [x] **Full Regression Matrix Passing**: All 23 native tests across 5 suites passed with 0 failures. Release build (`swift build -c release`) compiled and ad-hoc signed in `WarpNest.app` (`arm64`).
