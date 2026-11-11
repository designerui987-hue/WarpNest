# WarpNest

WarpNest is a free, native, open-source macOS application designed for installing, organizing, and running compatible Windows games using verified compatibility runtimes on Apple Silicon and modern macOS.

---

## Key Features

- **Native macOS Experience:** Designed and built with SwiftUI for macOS 14+ (Sonoma, Sequoia, and beyond).
- **Decoupled Architecture:** Clean separation between `WarpNestCore` (testable domain logic, process supervisor, and runtime adapters) and the macOS App Shell.
- **Robust Process Supervision:** Launches processes with explicit URL paths and argument arrays—never interpolating user input into shell strings. Concurrent stream draining into bounded ring buffers prevents log explosions and deadlocks.
- **Deterministic Compatibility Runtimes:** Full support for Wine-Staging, WineCX, and custom compatibility engines with WoW64 on Apple Silicon.
- **Safe Bottle Management:** Prefix isolation, per-bottle async mutexes to prevent concurrent conflicting operations, and zip archive backup/restore with path-traversal safeguards.
- **Privacy & Freedom First:** 100% free and open-source under the MIT license. Zero accounts, zero telemetry, no subscriptions, no ads, and no root/SIP-disabling required.

---

## Architecture Overview

```
WarpNest
├── Sources/WarpNestCore
│   ├── Models/               # Core data models (GameItem, Bottle, Configuration)
│   ├── Supervisor/           # Supervised process execution & bounded ring buffer
│   ├── Storage/              # Atomic JSON persistence & Application Support paths
│   ├── Runtimes/             # RuntimeAdapter protocol, TestRuntimeAdapter, WineRuntimeAdapter
│   ├── Bottles/              # Bottle provisioning, mutex locking, and backup/restore
│   ├── Library/              # Game indexing and launch lifecycle management
│   └── Diagnostics/          # Hardware diagnostics & redaction-aware log reporting
├── Sources/WarpNest
│   ├── App/                  # SwiftUI App lifecycle and main window
│   ├── ViewModels/           # Observable AppViewModel
│   └── Views/                # Library, Bottles, Diagnostics, and Settings views
└── Tests/WarpNestCoreTests   # Comprehensive unit and integration test suite
```

---

## Building from Source

### Prerequisites
- macOS 14.0 or newer
- Xcode 15+ (Xcode 27.2 verified)
- Swift 6.0+ toolchain

### Build Commands
```bash
# Build the native app and core libraries
swift build

# Run the complete automated test suite
swift test
```

---

## Documentation

- [docs/environment.md](docs/environment.md): Verified developer host specifications.
- [docs/implementation-plan.md](docs/implementation-plan.md): Architectural roadmap and milestones.
- [docs/runtime-evaluation.md](docs/runtime-evaluation.md): Technical evaluation of Apple Silicon compatibility runtimes (Wine-Staging, WineCX, DXVK, MoltenVK).
- [docs/progress.md](docs/progress.md): Live progress tracker and automated test evidence.

---

## License

WarpNest is licensed under the [MIT License](LICENSE).
