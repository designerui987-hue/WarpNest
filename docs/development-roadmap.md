# WarpNest Development Roadmap

**Project Scope:** Native macOS gaming platform running Windows games on Apple Silicon through Wine-compatible runtimes.  
**Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Package Manager, AppKit (for panels/windowing), Wine/WoW64 compatibility layer.

---

## 1. Current Capabilities (Verified from Code)

| Area | Verified Capabilities | Empirical Evidence |
| :--- | :--- | :--- |
| **Runtime Identity & Discovery** | Discovers standard Wine bundles (`/Applications/Wine Staging.app`, etc.) and user-imported roots. Persists runtime registry to `runtimes.json`. | Core unit tests pass; `wine-11.21 (Staging)` loaded from `/Volumes/Personal/WarpNest/Runtimes/`. |
| **Process Supervision** | Non-blocking stdout/stderr pipe reading via `readabilityHandler`. Ring buffer with 1 MB cap. Process group kill guarded by `getpgid`. | `ProcessSupervisorTests` pass (4 tests). Argument integrity with Unicode & spaces verified. |
| **Bottle Management** | Creation via `wineboot -u`. Per-launch session UUIDs and `BottleLockLease` owner tokens. Rejection of traversal paths. | `BottleAndLibraryTests` pass (5 tests). Locks prevent concurrent mutation during sessions. |
| **Archive Security & Backup** | Safe backup staged to `.staging_<UUID>.zip`. Atomic replacement. Symlink validation in restore rejects links targeting outside prefix (package inspection included). | `ArchiveSecurityAndIntegrityTests` pass (7 tests, including `testHiddenEscapingLinks`). |
| **Real Wine Execution** | Full prefix initialization, 64-bit/WoW64 execution, Windows GUI app launch (`notepad.exe`), Windows GUI game qualification (`winemine.exe`), cold-start restart rehydration. | `RealWineRuntimeDemonstrationTests` pass (4 tests). MoltenVK 1.4 / Metal Vulkan 1.4.323 active. |
| **Steam Verification** | Initial headless Steam installation verified (`SteamSetup.exe /S`), self-update to client build 1794424036, CEF login window initialized in logs. | `docs/steam-check-2026-11-13.md` and `scratch/steam-check/`. |

---

## 2. Prioritized Defects & Product Gaps

### Priority 1: High Risk / Data Safety / System Hangs
1. **Runtime Re-Import Overwrites Stable ID (P1):**
   - *Problem:* `AppViewModel.importRuntime` constructs a fresh `RuntimeID("wine-" + UUID())` even if the canonical root was already imported, removes the old entry from `runtimes.json`, and saves the new one. Existing bottles bound to the old ID become orphaned upon app restart.
   - *Fix:* Check canonical path against existing registry entries; reuse the established `id` when re-importing the same runtime. Propagate persistence errors.
2. **Synchronous `readDataToEndOfFile()` Hang on Descendant Pipes (P1):**
   - *Problem:* `ProcessSupervisor.handleTermination` calls `readDataToEndOfFile()` synchronously after direct process exit. If a descendant process (e.g., wine server/child, updater helper) inherits stdout/stderr and remains alive, the call blocks the actor indefinitely, breaking supervisor control and timeouts.
   - *Fix:* Replace `readDataToEndOfFile()` with non-blocking `availableData` draining.
3. **Missing Subprocess Timeout in Archive Operations (P2):**
   - *Problem:* `BottleService.executeSubprocess` accepts `timeoutSeconds: TimeInterval = 120` but never enforces a deadline. A stalled `zip`/`unzip` process deadlocks the bottle indefinitely.
   - *Fix:* Enforce deadline via an asynchronous timeout task that terminates stalled subprocesses.

### Priority 2: Inconsistent State Enforcement & UI Safety
4. **Runtime Verification Bypass in Launch & Settings (P2):**
   - *Problem:* Failed runtime validation is saved as `isVerified = false`, but `SettingsView` labels all non-simulated adapters "Verified", and `LibraryService.launchGame` does not check `adapter.descriptor.isVerified`.
   - *Fix:* Gate `launchGame` on `isVerified`. Accurately display unverified/missing runtimes in Settings and Bottle pickers.
5. **Missing Confirmation for Destructive Bottle Deletion:**
   - *Problem:* Clicking "Delete" in `BottlesView` deletes user prefixes and shortcuts immediately without confirmation.
   - *Fix:* Add an alert confirmation modal detailing the permanent deletion of game saves, prefixes, and shortcuts.
6. **Backup and Restore UI Gaps:**
   - *Problem:* Core backup and restore logic is implemented and tested, but there are no user-facing controls in `BottlesView`.
   - *Fix:* Add "Backup..." action per bottle and "Restore Bottle..." button in the header using native `NSSavePanel` / `NSOpenPanel`.

---

## 3. Phased Implementation Milestones

### Phase 1: Reliability & Data Safety (Immediate)
- **Milestone 1.1: Runtime Identity & Persistence Hardening**
  - Preserve stable runtime IDs across re-imports of the same root.
  - Propagate registry write errors honestly.
  - Enforce `isVerified` in `LibraryService.launchGame`.
  - Fix misleading "Verified" label in `SettingsView`.
- **Milestone 1.2: Bounded Non-Blocking Output Draining & Lifecycle**
  - Eliminate `readDataToEndOfFile()` blocking in `ProcessSupervisor.handleTermination`.
  - Add regression test with child process keeping output pipes open.
  - Model active sessions, updater restarts, and child lifetimes.
- **Milestone 1.3: Archive Subprocess Deadlines & UI Backup/Restore**
  - Implement real deadline-driven timeouts in `BottleService.executeSubprocess`.
  - Add confirmation alert for bottle deletion in `BottlesView`.
  - Expose backup and restore workflows in `AppViewModel` and `BottlesView`.

### Phase 2: Complete Steam Workflow
- **Milestone 2.1:** Official Steam installer download and checksum verification.
- **Milestone 2.2:** Guided in-app "Install Steam" workflow with progress and error recovery.
- **Milestone 2.3:** Handle Steam self-update, process restart tracking, and client initialization.
- **Milestone 2.4:** Discover installed Steam games and register shortcuts automatically.

### Phase 3: Real Graphics and Configuration Support
- **Milestone 3.1:** Graphics capability audit and detection (WineD3D, DXVK, MoltenVK Vulkan 1.4).
- **Milestone 3.2:** Explicit DLL overrides and backend activation validation (no silent fallback).
- **Milestone 3.3:** Accurate Windows version, High-DPI scaling, and sync backend configuration.

### Phase 4: Game Profiles & Dependency Recipes
- **Milestone 4.1:** Declarative recipe format for game dependencies (VC++, DirectX runtimes, .NET).
- **Milestone 4.2:** Dependency installation manager with progress and failure rollback.
- **Milestone 4.3:** Profile import/export and conflict detection across shared bottles.

### Phase 5: Polished Native macOS Experience
- **Milestone 5.1:** Onboarding flow and runtime setup guidance.
- **Milestone 5.2:** Game details view with settings, logs, and compatibility metadata.
- **Milestone 5.3:** Accessibility, keyboard navigation, and responsive states.

### Phase 6: Compatibility & Performance Qualification
- **Milestone 6.1:** Qualification matrix schema (System, Runtime, Graphics, Game version, Status).
- **Milestone 6.2:** Real performance telemetry (FPS, frame times, memory) where technically supported.
- **Milestone 6.3:** 10-game qualification suite with reproducible evidence logs.

### Phase 7: Differentiating Features
- **Milestone 7.1:** Pre-change bottle snapshots and point-in-time rollback.
- **Milestone 7.2:** Evidence-based automated configuration repairs.
- **Milestone 7.3:** Opt-in diagnostic bundles with sensitive path redaction.

### Phase 8: Release Engineering
- **Milestone 8.1:** Reproducible release bundling script.
- **Milestone 8.2:** Hardened runtime entitlements, Developer ID signing, and notarization workflows.
- **Milestone 8.3:** Release notes, provenance notices, and distribution packaging.

---

## 4. Dependencies & Unresolved Technical Decisions

1. **Host Architecture Target:** Currently Apple Silicon (`arm64`) using Rosetta 2 translation for `x86_64` Wine and New WoW64 for 32-bit Windows code. Intel testing remains pending physical hardware access.
2. **Steam Hardware Acceleration:** Steam CEF web helper currently disables GPU acceleration due to DXGI/GLES error logs on macOS Wine. Must verify whether software rendering fallback is acceptable or if MoltenVK flags can re-enable hardware acceleration.
3. **Process Tracking across Restarts:** Wine launcher processes terminate while wineserver and child processes remain active. Session tracking must rely on wineserver status or session-specific child tree inspection rather than single PID polling.
