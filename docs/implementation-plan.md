# WarpNest Implementation Plan

## Architecture Overview
WarpNest is architected cleanly with separation between domain logic and presentation:
1. **`WarpNestCore`**: An independently testable Swift package containing:
   - `ProcessSupervisor`: Supervised process execution with explicit argument arrays, bounded concurrent stream draining, and robust session lifecycle tracking.
   - `BottleService`: Wine prefix / bottle provisioning, configuration, atomic metadata operations, per-bottle operation serialization, and secure backup/restore.
   - `LibraryService`: Game catalog indexing, shortcut vs bottle lifecycle decoupling, metadata persistence.
   - `RuntimeRegistry` & `RuntimeAdapter`: Protocol-based compatibility layer supporting both production runtimes (e.g., Wine-Staging, WineCX) and deterministic test adapters.
   - `MetadataStore`: Atomic filesystem storage located in `~/Library/Application Support/WarpNest/` with versioned schema migration support.
   - `DiagnosticsService`: Bounded log ring buffers, hardware/OS environment reporting, and one-click diagnostic export.
2. **`WarpNest` (App Shell & UI)**: Native SwiftUI application conforming to modern macOS human interface principles:
   - Sidebar with Library, Bottles, Runtimes, Diagnostics, and Settings.
   - Library view with Grid/List toggling, search, category filtering, and game detail panel.
   - Direct Play/Stop controls with real-time supervision status.
   - Wizard for bottle creation and Windows executable / installer importing.
   - Live bounded log inspector and runtime configuration editor.

---

## Milestone 1: Environment & Project Foundation
- **Goal:** Establish developer environment documentation, version control conventions, and project workspace.
- **Deliverables:**
  - `docs/environment.md`
  - `docs/implementation-plan.md`
  - `docs/progress.md`
  - Git repository setup with comprehensive `.gitignore`
- **Acceptance Criteria:**
  - Environment details validated on host.
  - Clean git status with sensible ignore rules.

---

## Milestone 2: Runtime Evaluation & Compatibility Strategy
- **Goal:** Research, evaluate, and document maintained macOS compatibility runtimes on Apple Silicon.
- **Deliverables:**
  - `docs/runtime-evaluation.md`
  - `RuntimeAdapter` protocol and runtime descriptor models.
  - `TestRuntimeAdapter` for deterministic local CI/unit testing.
  - `WineRuntimeAdapter` for production Wine execution with bottle creation, wineboot, and process launching.
- **Acceptance Criteria:**
  - Evaluation of Wine distributions (Wine-Staging, CrossOver/WineCX, GPTK).
  - Clear delineation between graphics translation (DXVK, MoltenVK, D3DMetal), instruction translation (Rosetta 2), and OS API translation (Wine).
  - Licensing analysis ensuring strictly GPL/LGPL/MIT compliance with zero proprietary or unauthorized binary bundling.

---

## Milestone 3: Core Domain Services Implementation
- **Goal:** Implement the business logic and system interfaces in `WarpNestCore`.
- **Deliverables:**
  - `ProcessSupervisor`: Asynchronous execution, pipe draining, bounded ring buffer, no shell string interpolation.
  - `BottleService`: Directory isolation, bottle lifecycle, per-bottle async mutex/coordination, zip backup/restore with path traversal guards.
  - `LibraryService`: Game entity CRUD, launch orchestration, session state reporting.
  - `MetadataStore`: Thread-safe, atomic JSON persistence, backup copy management.
  - `DiagnosticsService`: In-memory log capture with limits, exportable redaction-aware diagnostics bundle.
- **Acceptance Criteria:**
  - Zero crashes on malformed files or failed processes.
  - Absolute paths strictly used; shell string injection rendered impossible by type design.
  - Atomic writes prevent partial file corruption.

---

## Milestone 4: Comprehensive Test Suite
- **Goal:** Ensure complete reliability and safety with automated tests.
- **Deliverables:**
  - Unit tests for `MetadataStore` (read, write, atomic replacement, corruption handling).
  - Unit tests for `ProcessSupervisor` (execution, exit code tracking, stdout/stderr retention, termination).
  - Unit tests for `BottleService` (creation, duplicate prevention, concurrent lock rejection).
  - Unit tests for Archive Backup/Restore (verifying rejection of path traversal `../` attacks and symlinks).
  - Unit tests for `LibraryService` (game addition, removal decoupling from bottle deletion).
- **Acceptance Criteria:**
  - 100% passing automated test suite executed via `swift test` and Xcode test schemes.

---

## Milestone 5: Polished Native macOS User Interface
- **Goal:** Build a macOS SwiftUI interface complying with Apple design guidelines.
- **Deliverables:**
  - Main app window with native `NavigationSplitView`.
  - Library Grid and List views with responsive card layouts and search.
  - Game Detail view with artwork banner, bottle info, launch parameters, and Play/Stop button.
  - Bounded Live Log Console with copy/export functionality.
  - Bottle Management view with create, inspect, backup, and restore sheets.
  - Diagnostics & System Information view.
  - Settings window for default paths and preferences.
- **Acceptance Criteria:**
  - Responsive at standard resolutions (1280 × 800 reference).
  - Full support for macOS Light and Dark appearance.
  - Accessible VoiceOver labels and keyboard shortcuts.
  - Polished empty, loading, and error states.

---

## Milestone 6: Open-Source Documentation & Quality Assurance
- **Goal:** Prepare production-grade documentation and repository structure.
- **Deliverables:**
  - `README.md`, `LICENSE` (MIT), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`.
  - Issue templates and Pull Request template (`.github/`).
  - GitHub Actions CI workflow for macOS builds and tests.
- **Acceptance Criteria:**
  - All open-source health files in place.
  - Clear instructions for contributors, building from source, and reproducible testing.
