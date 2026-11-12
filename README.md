# WarpNest

WarpNest is a free, open-source native macOS application designed to organize, configure, and run Windows games and applications on Apple Silicon (arm64) and Intel Macs using verified compatibility runtimes (Wine / WoW64).

## Current Status & Verification Tiers

To maintain strict engineering transparency, WarpNest features are categorized into four verification tiers:

| Component / Feature | Verification Tier | Notes |
| :--- | :--- | :--- |
| **SwiftUI Multi-Pane Architecture** | **Implemented & Verified** | Native `NavigationSplitView` with Library, Bottles, Diagnostics, and Settings views. |
| **Process Supervision (`ProcessSupervisor`)** | **Implemented & Verified** | Actor-based execution, array-based argument passing (no shell interpolation), streaming stdout/stderr pipe draining, bounded ring buffer. |
| **Session & Bottle Locking** | **Implemented & Verified** | Mutex locking prevents concurrent destructive actions (backup, deletion) while game sessions are preparing or active. |
| **Settings & State Persistence** | **Implemented & Verified** | Atomic JSON persistence with `.tmp` swapping for library shortcuts, bottles, and settings. |
| **Zip Backup & Safe Restore** | **Implemented & Verified** | Symlink-preserving zip backup (`-y`) and table-of-contents validation rejecting path traversal attacks (`../`). |
| **Simulated Test Adapter (`TestRuntimeAdapter`)** | **Implemented (Explicit Test Mode)** | Isolated behind Developer/Test mode toggle; runs deterministic mock processes (`/bin/echo`) and is never silently substituted for real Wine runtimes. |
| **Wine Runtime Adapter (`WineRuntimeAdapter`)** | **Implemented** | Supports standard UNIX layout (`bin/wine`) and macOS app bundles (`Contents/Resources/wine/bin/wine`). Lazily verified via `wine --version` before bottle creation is unlocked. |
| **Real Windows GUI App Launch** | **Pending Host Runtime** | No pre-existing Wine runtime or Windows binary was detected on the current Mac system. Real wine execution will be enabled as soon as a runtime is imported. |

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
