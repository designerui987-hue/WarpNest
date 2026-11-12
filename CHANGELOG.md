# Changelog

All notable changes to **WarpNest** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0-alpha] - 2026-11-12

### Fixed
- **WN-01 / WN-12 (Executable Path & CWD Resolution):** Resolved absolute Unix paths for game executables inside prefix with canonical symlink validation; supported explicit external installers with `isExternalExecutable`; protected reserved Wine environment keys (`WINEPREFIX`, `WINESERVER`, `WINELOADER`, `WINEDLLPATH`, `WINEDEBUG`) from being overridden by bottle or game configurations.
- **WN-02 (Archive Pipe Deadlocks):** Replaced blocking `waitUntilExit()` reads with non-blocking continuous `readabilityHandler` draining for `zip`, `zipinfo`, and `unzip` operations, preventing buffer backpressure deadlocks on large file collections.
- **WN-03 (Runtime Registry Persistence):** Implemented `PersistedRuntime` with stable, collision-free UUID-based identifiers saved to `runtimes.json`; rehydrated runtimes on cold launch and marked missing runtimes gracefully without silent substitution.
- **WN-04 (Bounded Process Supervision):** Enforced byte-limited log retention (1 MB cap) in `LogRingBuffer` to prevent unbounded memory usage; guarded process group termination (`getpgid(pid) == pid`) before sending `kill(-pid)`.
- **WN-05 (Session & Lock Ownership):** Introduced unique per-launch session IDs and `BottleLockLease` owner tokens; prevented obsolete completion callbacks from unlocking newly relaunched sessions; reserved bottle locks atomically with rollback on build failure.
- **WN-06 (Multi-Window Service Isolation):** Shifted `AppViewModel` ownership to `@main WarpNestApp` level, sharing a single application-scoped service container across all window scenes in `WindowGroup`.
- **WN-07 (Archive Symlink & Prefix Structure Validation):** Inspected extracted symbolic link targets to detect and reject traversal escapes pointing outside the restore root; verified presence of valid Wine prefix components (`drive_c`, `system.reg`, or `warpnest_bottle.json`) before registering restored bottles.
- **WN-08 (Staged Atomic Backup & Honest Deletion):** Switched backup creation to temporary staging archive files (`.staging_*.zip`) with atomic replacement (`replaceItemAt`), preserving prior good backups on failure; propagated directory deletion errors honestly without dropping metadata.
- **WN-09 (Simulation Mode Cleanup):** Cleanly unregistered the `TestRuntimeAdapter` when Developer Mode is disabled in Settings; added visual `[SIMULATED]` indicators on cards and pickers.
- **WN-10 (Authoritative Session States & Live Logs):** Only emitted `.running` state once child process spawn succeeds; bound live log handlers so logs stream into the Diagnostics view.
- **WN-11 (Supported Settings Defaults):** Seeded the bottle creation dialog's sync backend directly from `AppSettings.defaultSyncBackend`.
- **WN-13 (Native Regression Test Matrix):** Replaced stub tests with real archive fixtures (crafted traversal entries and escaping symlinks using `zipfile`), argument integrity tests, byte retention limits, and prefix structure validation.
- **WN-14 (Architecture Clarification):** Marked development build as alpha targeting Apple Silicon ARM64, narrowing Intel claim until verified on physical Intel hardware.
- **WN-15 (Metadata Compatibility & Diagnostics):** Added backward-compatible migration for legacy `d3dMetal` configurations to `.dxvk`; preserved corrupt metadata files as `.corrupt.<timestamp>` for user recovery; dynamically derived host architecture in `DiagnosticsService`.

## [0.1.0] - 2026-11-11

### Added
- Initial developer preview with SwiftUI multi-pane UI, actor-based `WarpNestCore`, `ProcessSupervisor`, `BottleService`, and `LibraryService`.
