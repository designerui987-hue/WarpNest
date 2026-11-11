# WarpNest Development Environment Specification

## System Environment
- **Operating System:** macOS 27.2 (Build 26B123)
- **Host Architecture:** `arm64` (Apple Silicon)
- **CPU Translation Support:** Rosetta 2 active and verified (`/usr/bin/arch -x86_64 /usr/bin/uname -m` executes successfully)
- **System Memory:** 16 GB unified memory (17,179,869,184 bytes)
- **Available Disk Storage:** 207 GiB available on `/System/Volumes/Data` (31% capacity used)

## Toolchain & Developer Tools
- **Developer Directory:** `/Applications/Xcode.app/Contents/Developer`
- **Xcode Version:** 27.2 (Build version 27B52)
- **Swift Compiler:** Apple Swift version 6.4.2 (swift-driver 1.168.6, clang-2100.4.1.1)
- **Compilation Target:** `arm64-apple-macosx27.2.0`
- **Installed Platform SDKs:**
  - macOS 27.2 (`macosx27.2`)
  - iOS 27.2 (`iphoneos27.2`, `iphonesimulator27.2`)
  - tvOS 27.2 (`appletvos27.2`, `appletvsimulator27.2`)
  - visionOS 27.2 (`xros27.2`, `xrsimulator27.2`)
  - watchOS 27.2 (`watchos27.2`, `watchsimulator27.2`)
  - DriverKit 27.2 (`driverkit27.2`)

## Project Target & Compatibility
- **Primary Deployment Target:** macOS 14.0 (Sonoma) or newer, supporting macOS 14, 15, and 27.
- **Language Mode:** Swift 6 with structured concurrency (`async`/`await`, `Sendable`, actors).
- **UI Framework:** SwiftUI native interface, Observation framework (`@Observable`), AppKit integration only where justified for macOS desktop integration (file panels, process notifications).
- **Core Package Architecture:** Modular separation between `WarpNestCore` (headless domain logic, process supervisor, bottle management, registry) and `WarpNest` (native macOS SwiftUI user interface).
- **Privacy & Security Guarantee:** Zero personal identifiers, zero telemetry, no third-party cloud requirements, no root/sudo privileges needed, and SIP/Gatekeeper compliant.
