# Contributing to WarpNest

Thank you for your interest in contributing to WarpNest! WarpNest is an open-source, community-driven project dedicated to native, dependable Windows gaming compatibility on macOS.

---

## Code of Conduct

All contributors and participants are expected to adhere to our [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Development Setup

1. Clone this repository locally.
2. Ensure Xcode 15 or newer is installed with command-line tools.
3. Build the project using:
   ```bash
   swift build
   ```
4. Run the automated test suite:
   ```bash
   swift test
   ```

---

## Architectural Principles

1. **Security & Input Handling:** Never interpolate strings into shell commands (`/bin/sh -c`). Always invoke executables via explicit file URLs and argument arrays.
2. **Swift Concurrency:** All shared mutable state should be protected via Swift Actors (`actor`). UI operations must be isolated to `@MainActor`.
3. **Decoupled Architecture:** Business logic lives in `Sources/WarpNestCore`. The user interface in `Sources/WarpNest` should remain thin and declarative.
4. **Honest Compatibility:** Only expose features and backends verified on host. Do not market experimental toggles as universal fixes.

---

## Submitting Pull Requests

1. Create a feature branch from `main`.
2. Ensure all existing tests pass (`swift test`) and add new tests covering your changes.
3. Keep pull requests focused on a single change or feature.
4. Open a pull request describing the rationale and verification steps.
