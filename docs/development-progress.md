# WarpNest Development Progress

## Status Overview
- **Active Phase:** Batch 1 Complete (Truthful Runtime & Correctness) → Transitioning to Phase 2 (Steam Workflow)
- **Current Milestone:** Batch 1 Verified (36 tests passing across 6 suites)
- **Repository Branch:** `repair/wn-fixes`
- **Host Target:** macOS 27.2 (`arm64`), Apple Silicon, Swift 6 toolchain
- **Automated Test Matrix:** 36 tests across 6 suites passing (`swift test`, 44.8s)

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
  - **Regression Tests:** Added `testRuntimeReimportPreservesID` and `testUnverifiedRuntimeLaunchRejection` to `BottleAndLibraryTests`. Both passed.

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

### Batch 1: Correctness and Truthful Runtime Behavior (18 Nov 2026)
- [x] **Simulation-Mode Registration Identity Alignment:**
  - Standardized the mock simulation adapter ID on canonical `RuntimeID("test-simulation")` across `TestRuntimeAdapter` and `AppViewModel`.
  - Disabling Developer Mode now accurately unregisters the adapter, preventing simulated launches and removing the mock adapter from UI selection.
  - Regressions: Added `testDeveloperModeSimulationIDConsistency` and `testSimulatedLaunchRejectedWithoutAdapter`.
- [x] **Truthful Graphics & Capability Claims:**
  - Relabeled `GraphicsBackend.dxvk` to `"DXVK (not installed — sets renderer hint only)"` to eliminate deceptive claims of integrated Vulkan/Metal translation.
  - Relabeled `GraphicsBackend.wineD3D` to `"WineD3D (built-in Wine D3D translation)"`.
  - Added computed properties `isInstallRequired` and `capabilityNote` explaining configuration requirements in `BottlesView`.
  - Added backward-compatible JSON decoding migration mapping legacy `d3dMetal`, `D3DMetal`, and verbose raw strings to their respective canonical enum cases.
  - Regressions: Added `testDxvkIsNotClaimedAsInstalled` and `testLegacyGraphicsBackendStringDecoding`.
- [x] **Authoritative Session State Lifecycle:**
  - Updated `LibraryService.getSessionState(for:)` to treat session-entry presence in `activeSessions` as authoritative (`.running` vs `.stopped`), preventing erroneous `.stopped` reports during launcher exit when child/prefix activities continue.
  - Scoped polling and teardown strictly to immutable session IDs (`UUID`) to discard stale callbacks.
  - Regressions: Added `testSessionStateAuthoritativeDuringContinuation` and `testStaleCallbackDoesNotAffectNewerSession`.
- [x] **Verifiable Shutdown & Process Termination:**
  - Added `ProcessSupervisor.waitForExit(timeoutSeconds:)` polling with deadlines.
  - Updated `LibraryService.stopGame(id:)` to verify actual process exit before releasing locks, transitioning state to `.failed` if shutdown cannot be confirmed within 5s.
  - Handled stop requests arriving prior to process launch safely without crashing or leaking locks.
  - Regression: Added `testStopBeforeSpawnIsNoop`.

---

## Next Milestone
- **Phase 2: Complete Steam Workflow**
  - Dedicated Steam bottle creation with optimal defaults.
  - Official installer download with SHA-256 integrity validation (`https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`).
  - Headless/silent installation handling and self-update progress tracking across process restarts.
  - Steam client shortcut registration and visual CEF login window verification.
