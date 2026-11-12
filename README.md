# WarpNest (Alpha)

WarpNest is an open-source native macOS application designed to organize, configure, and manage Windows game bottles on Apple Silicon (arm64) using verified compatibility runtimes (Wine / WoW64). Intel (x86_64) support is planned for future validation on physical hardware.

> [!NOTE]
> **Build Status:** v0.2.0-alpha (Milestone 3/QA Repair Pass Completed). Tested on Apple Silicon macOS 27.2 with Swift 6 strict concurrency. Real Windows GUI app execution is pending import of a supported host Wine runtime bundle.

## Current Status & Verification Tiers

To maintain strict engineering transparency, WarpNest features are categorized into four verification tiers based on automated native test evidence:

| Component / Feature | Verification Tier | Notes |
| :--- | :--- | :--- |
| **SwiftUI Architecture & Multi-Window Sharing** | **Implemented & Verified** | Single application-scoped service container (`AppViewModel`) shared across all windows (WN-06). Native `NavigationSplitView`. |
| **Process Supervision (`ProcessSupervisor`)** | **Implemented & Verified** | Asynchronous non-blocking readability handlers (deadlock-free), array-based argv/cwd without shell interpolation, byte-limited ring buffer (WN-04). |
| **Session & Bottle Locking** | **Implemented & Verified** | Cryptographic/UUID-based lock leases, owned tokens, stale callback protection preventing premature unlock or orphaned sessions (WN-05). |
| **Settings & State Persistence** | **Implemented & Verified** | Atomic JSON persistence with `.tmp` swapping for library shortcuts, bottles, settings, and runtime registries (WN-03). Corrupt data preserved for recovery (WN-15). |
| **Zip Backup & Safe Restore** | **Implemented & Verified** | Concurrent non-blocking pipe draining (WN-02), staged atomic replacement (WN-08), escaping symlink & traversal rejection, and Wine prefix structure validation (WN-07). |
| **Simulated Test Adapter (`TestRuntimeAdapter`)** | **Implemented (Explicit Test Mode)** | Isolated behind Developer Mode toggle; cleanly unregistered when Developer Mode is disabled (WN-09). Visual `[SIMULATED]` indicators on cards and pickers. |
| **Wine Runtime Adapter (`WineRuntimeAdapter`)** | **Implemented & Verified** | Strict validation requiring `wine`, `wineboot`, and `wineserver` companion executables with execution permissions. Bounded `wine --version` check (WN-12). |
| **Path Resolution & WINEPREFIX Protection** | **Implemented & Verified** | Canonical symlink resolution, bottle boundary containment, explicit external installer support, and reserved environment key protection (WN-01, WN-12). |
| **Real Windows GUI App Launch** | **Pending Host Runtime** | No pre-existing Wine runtime or Windows binary was detected on the development Mac. Real wine execution will be demonstrated as soon as a runtime is imported. |

## Quick Start (Developer / Test Mode)

1. Clone or open the project in Xcode or Terminal.
2. Build and run:
   ```bash
   swift build
   swift test
   swift run WarpNest
   ```
3. To test UI flows without an external Wine installation, open **Settings**, toggle **Enable Developer / Simulated Mode**, and navigate to **Bottles** or **Library**.

## Importing a Real Wine Runtime

1. Obtain a verified macOS Wine build (e.g. Wine-Staging or custom WineCX build).
2. In WarpNest, go to **Settings** -> **Import Wine Runtime...** and select the root directory or `.app` bundle.
3. WarpNest validates executable permissions and runs `wine --version` to query capabilities. Once validated, real bottle creation is unlocked.

## License

MIT License. See [LICENSE](LICENSE) for details.
