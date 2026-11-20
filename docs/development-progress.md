# WarpNest Development Progress

## Status Overview
- **Active Phase:** Phase 2 (Complete Steam Workflow & Game Discovery Delivered)
- **Current Milestone:** Phase 2 Complete (53 tests passing across 9 suites)
- **Repository Branch:** `main`
- **Host Target:** macOS 14+ / Apple Silicon (`arm64`), Swift 6 toolchain
- **Automated Test Matrix:** 53 tests across 9 suites passing (`swift test`, ~15s)

---

## Completed Milestones

### Pre-Phase: Baseline & Security Audit (13 Nov 2026)
- [x] **Symbolic Link Validation in Restore:** Hardened `BottleService.validateRestoredSymbolicLinks(in:)` to inspect package descendants and restrict host-targeting links strictly to root drive mappings (`dosdevices/c:`, `dosdevices/z:`). 7 archive security tests passing.
- [x] **Development Roadmap Established:** Created `docs/development-roadmap.md` mapping out 8 phases, prioritized defects, acceptance criteria, and unresolved decisions.

### Phase 1: Reliability and Data Safety (13 Nov 2026)
- [x] **Sub-Milestone 1.1: Runtime Identity & Persistence Hardening**
  - **Re-import Stable ID Preservation:** In `AppViewModel.importRuntime`, checked existing entries in `persisted` matching `canonicalURL.path` and preserved `existingEntry.id` as `stableID` instead of generating a random UUID that would orphan existing bottles.
  - **Honest Persistence Propagation:** Replaced `try?` with `try await metadataStore.saveRuntimeRegistry(persisted)` to bubble up filesystem failures.
  - **Enforce Runtime Verification at Launch:** In `LibraryService.launchGame`, added `guard adapter.descriptor.isVerified else { throw LibraryServiceError.runtimeUnavailable(...) }`.
  - **Accurate Status Display in UI:** Updated `SettingsView` to display `"Unverified"` in red when `r.isVerified == false` (no longer falsely labels unverified runtimes as `"Verified"`). Marked unverified runtimes in `BottlesView` picker.
  - **Regression Tests:** Added `testRuntimeReimportPreservesID` and `testUnverifiedRuntimeLaunchRejection` to `BottleAndLibraryTests`.

- [x] **Sub-Milestone 1.2: Bounded Non-Blocking Output Draining & Process Lifecycle**
  - **Eliminated Descendant Pipe Hangs:** Replaced blocking `readDataToEndOfFile()` in `ProcessSupervisor.handleTermination` with POSIX `O_NONBLOCK` file descriptor draining (`drainNonBlocking`) and explicit handle closure.
  - **Launcher vs Game Process Decoupling:** Added `isPrefixRunning(at:)` checking `wineserver -k0`. When an initial launcher process exits while wineserver/child processes remain active in the prefix, `LibraryService` preserves the active session and holds the bottle lock until the prefix actually terminates.
  - **Regression Test:** Added `testSupervisorDoesNotHangWhenChildRetainsPipe` to `ProcessSupervisorTests`. Confirmed parent exit completes in 0.010s without waiting 5s for the surviving background child.

- [x] **Sub-Milestone 1.3: Archive Subprocess Deadlines & UI Safety**
  - **Enforced Archive Subprocess Deadlines:** Updated `BottleService.executeSubprocess` to apply `timeoutSeconds` via a supervised cancellation task, killing stalled processes with `SIGTERM`/`SIGKILL` and throwing `BottleServiceError.subprocessTimedOut`.
  - **Non-Blocking Pipe Draining in Archive Operations:** Applied `O_NONBLOCK` draining to `executeSubprocess`.
  - **Exposed Backup & Restore in UI:** Added `viewModel.backupBottle` and `viewModel.restoreBottle` workflows to `AppViewModel`. Added "Restore Bottle..." button in `BottlesView` header and "Backup..." button per bottle card with native `NSOpenPanel`/`NSSavePanel`.
  - **Destructive Deletion Confirmation:** Added `.confirmationDialog` before bottle deletion in `BottlesView` detailing the permanent loss of prefixes, registry, and local game saves.
  - **Regression Test:** Added `testSubprocessTimeoutEnforcement` to `ArchiveSecurityAndIntegrityTests`. Confirmed subprocess killed and error thrown within 0.53s.

### Batch 1: Correctness, Authoritative State, Task Cancellation & Truthful Capabilities (18-19 Nov 2026)
- [x] **Bounded Shutdown Verification & Recovery (Item 1):**
  - Replaced unverified stop and lock release with deterministic process and prefix exit verification (`waitForExit(5.0)` and `waitForPrefixInactivity(timeout: 5.0)`).
  - Unsuppressed prefix stop errors in `WineRuntimeAdapter.stopPrefix(at:)` and verified `wineserver -k` status.
  - On shutdown failure or timeout, `LibraryService` retains the session and bottle lock, transitioning to explicit `SessionState.stopFailed`.
  - UI exposes a prominent red "Retry Stop" action in `LibraryView` when a session is in `stopFailed`.
- [x] **Authoritative Stored Session State (Item 2):**
  - Replaced fragile presence checks (`activeSessions[id] != nil => .running`) with an explicit stored `sessionStates: [GameID: SessionState]` dictionary in `LibraryService`.
  - State transitions are published through `statePublisher` and strictly agree across queries and reactive subscribers across `.stopped`, `.preparing`, `.running`, `.stopping`, `.failed`, and `.stopFailed`.
  - Immediate pre-flight rejections (e.g. unverified runtime) synchronously update state to `.failed` and notify listeners without leaving orphan preparation states.
- [x] **Task Ownership, Scoping & Pre-Spawn Cancellation (Item 3):**
  - Stored `launchTask` and `pollingTask` directly within `ActiveSession`.
  - Scoped all asynchronous callbacks and lifecycle hooks to immutable session IDs (`UUID`), safely discarding delayed callbacks from older sessions.
  - Calling `stopGame` while a game is still in `.preparing` cancels the `launchTask` immediately, aborting the process before spawn and releasing session locks.
  - Playtime calculation and state finalization are guarded by atomic `isFinalized` ensuring exact-once execution across natural exits and manual stops.
- [x] **Deterministic Regression Scenarios (Item 4):**
  - Rewrote lifecycle tests using deterministic actors, mock processes, and sync gates rather than arbitrary `Task.sleep` timeouts:
    1. Launcher exits while controlled prefix stays active, preserving session and lock.
    2. Stop arriving during preparation prevents process spawn and clears session lock.
    3. Session B is not disrupted by a delayed callback from session A.
    4. Prefix shutdown failure preserves session and lock in recoverable Stop Failed state.
    5. State queries accurately reflect preparing, stopping, and failure states.
    6. Simulated launch rejected when developer mode adapter is unregistered.
    7. Developer mode on/off in the same session uses consistent simulation ID.
    8. Legacy runtimeID "test-adapter-v1" migrates to canonical simulation ID.
    9. Mach-O architecture detection truthfully identifies binaries without hardcoding.
    10. D3DMetal configuration throws unsupportedConfiguration on execution plan build.
    11. Legacy D3DMetal decodes truthfully as `.d3dMetal` and is never silently substituted for DXVK.
- [x] **Simulation Migration & Shared Constant (Item 5):**
  - Defined canonical `RuntimeID.simulation = RuntimeID("test-simulation")` and `RuntimeID.legacySimulation = RuntimeID("test-adapter-v1")`.
  - `Bottle.init(from decoder:)` and `BottleService.loadBottles()` transparently detect legacy `test-adapter-v1` and migrate persisted bottles and shortcuts to `.simulation`.
  - `AppViewModel` unregisters both IDs when Developer Mode is toggled off.
- [x] **Truthful Capabilities & Architecture Detection (Item 6):**
  - Eliminated universal hardcoded `["x86_64", "arm64"]` claims in `WineRuntimeAdapter`; implemented direct Mach-O binary header inspection (`detectArchitectures(for:)`) using `lipo` / Mach-O magic numbers.
  - Introduced explicit `GraphicsBackend.d3dMetal = "Apple D3DMetal (unsupported / not distributed)"` with `isSupported = false` and `isInstallRequired = true`.
  - Stopped silently aliasing legacy D3DMetal configurations to DXVK hints; `WineRuntimeAdapter.buildExecutionPlan` throws `RuntimeAdapterError.unsupportedConfiguration` if D3DMetal is configured.
  - Disabled unsupported graphics backends in the `BottlesView` picker and blocked bottle creation with unsupported options.
  - Documented in `SettingsView` and `BottlesView` that Retina and Windows version settings depend on prefix-level Wine driver support.

---

## Verified Test Matrix Summary (Commit Baseline)
- **Total Tests Executed:** 44
- **Passing:** 44
- **Failing:** 0
- **Skipped / Untested:** 0
- **Suites:**
  - `WarpNestCore Metadata & Storage Tests` (6/6 passing)
  - `Bottle & Library Integration Tests` (4/4 passing)
  - `Archive Security & Integrity Tests` (7/7 passing)
  - `Batch 1 Regression Tests` (11/11 passing)
  - `Manual Verification Checklist Tests` (4/4 passing)
  - `ProcessSupervisor Tests` (6/6 passing)
  - `Real Wine Runtime Demonstration Tests` (6/6 passing — real prefix creation, WineMine launch, lifecycle)

---

### Phase 2: Complete Steam Workflow, Download, Verification & Game Discovery (20-21 Nov 2026)
- [x] **Secure Official Installer Downloader (`SteamDownloaderService`):**
  - Official Fastly CDN endpoint (`https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`).
  - Strict SHA-256 integrity verification against verified checksum (`7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`).
  - Streaming byte-level download with live progress callback `(bytesReceived, totalBytes, fraction)`.
  - Fast cache check: automatically skips redundant network download when a verified installer is already present on disk.
- [x] **ACF KeyValues Parser & Steam Game Discovery (`SteamAppDiscoveryService`):**
  - Parses Valve KeyValues `appmanifest_*.acf` files in `steamapps/` prefixes.
  - Automatically maps installed Steam games, resolving AppIDs, install directories, and primary executables in `common/<installdir>`.
  - Exposes `discoverGames(in:)` and library shortcut generation (`addDiscoveredGame`).
- [x] **In-App Steam Installation & Discovery UI Workflows:**
  - Dedicated "Install Steam" action in Library header and empty states.
  - `SteamInstallSheet` with environment selection (create dedicated "Steam" bottle or use existing), live progress bar with MB/percentage, cancellation, and error retry.
  - Silent setup invocation (`/S`) inside isolated prefix.
  - `SteamDiscoverySheet` and context menu on Steam items for discovering and adding installed Steam games directly to the WarpNest library.
- [x] **Installer-to-Installed-App Handoff for Steam:**
  - Added `locateInstalledExecutable(named:in:)` to `BottleService` to locate `Steam.exe` inside bottle prefix hierarchies (`drive_c/Program Files (x86)/Steam/Steam.exe`, `drive_c/Program Files/Steam/Steam.exe`).
  - Added `updateGameTarget` to `LibraryService` to safely mutate and persist the target executable path and name.
  - Implemented automatic detection and confirmation banner in `LibraryView` and `AppViewModel` (`pendingInstallerHandoff`).
  - Preserved standalone executable behavior: standard game shortcuts without installer semantics run normally without handoff prompts.
  - Handled installer failure/cancellation: environment and files are strictly preserved with options to **Retry Setup** or **Choose Installed App…**.
  - Added regression test suites `SteamInstallerHandoffTests` and `SteamWorkflowTests`.

---

## Verified Test Matrix Summary (Commit Baseline)
- **Total Tests Executed:** 53
- **Passing:** 53
- **Failing:** 0
- **Skipped / Untested:** 0
- **Suites:**
  - `Steam Workflow Tests` (5/5 passing - SHA-256 verification, cache hit skip, ACF manifest parser, prefix game discovery, library shortcut handoff)
  - `Steam Installer Handoff Tests` (4/4 passing)
  - `WarpNestCore Metadata & Storage Tests` (6/6 passing)
  - `Bottle & Library Integration Tests` (4/4 passing)
  - `Archive Security & Integrity Tests` (7/7 passing)
  - `Batch 1 Regression Tests` (11/11 passing)
  - `Manual Verification Checklist Tests` (4/4 passing)
  - `ProcessSupervisor Tests` (6/6 passing)
  - `Real Wine Runtime Demonstration Tests` (6/6 passing — real prefix creation, WineMine launch, lifecycle)

---

## Manual Verification Checklist for Real-Mac Steam Sign-In
The following steps cannot be validated by headless automated tests and require a physical Mac with GPU display and user credentials:
1. **Interactive Visual Login Window Verification:**
   - Launching the confirmed `Steam.exe` executable inside Wine.
   - Verifying the CEF (Chromium Embedded Framework) desktop login window displays visually without black screens or crashes on Apple Silicon.
2. **User Authentication & Guard:**
   - Entering real Steam account credentials, 2-Factor Steam Guard code, or QR code scan via mobile app.
3. **Steam Store & Download Test:**
   - Accessing Steam Store/Library, downloading a small free Windows game (e.g., *Peggle*, *Spelunky Classic*, or free demo), and verifying download progress.
4. **Direct Game Launch through Steam:**
   - Clicking Play on an installed Steam game and confirming game execution within the managed bottle.
