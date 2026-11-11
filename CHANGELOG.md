# Changelog

All notable changes to **WarpNest** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-11

### Added
- Native SwiftUI user interface supporting macOS Sonoma (macOS 14) and newer.
- `WarpNestCore` architecture separating business logic from UI.
- Supervised process execution (`ProcessSupervisor`) with argument arrays and concurrent stdout/stderr draining into bounded ring buffers.
- `BottleService` with thread-safe prefix management, async operation mutexes, and secure zip backup/restore with path-traversal rejection.
- Protocol-based `RuntimeAdapter` supporting `WineRuntimeAdapter` and `TestRuntimeAdapter`.
- `LibraryService` with game shortcut indexing and clean decoupling from prefix deletion.
- Comprehensive automated test suite validating metadata persistence, supervisor termination, bottle provisioning, and archive safety.
- Complete open-source documentation suite: README, LICENSE (MIT), CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, and THIRD_PARTY_NOTICES.
