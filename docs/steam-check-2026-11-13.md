# Steam compatibility check — 13 November 2026

## Result

Partial compatibility verified: installation, updating, client startup, and login-window initialization succeeded. Account login, Store interaction, downloads of games, and gameplay were not tested. No credentials were entered.

## Setup

- User-supplied installer: `/Users/neerajgopi/Downloads/SteamSetup.exe`.
- SHA-256: `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`.
- File matched a fresh HTTPS download from `https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`, the official Steam distribution endpoint linked by https://store.steampowered.com/about/ .
- Wine runtime: Wine-Staging 11.21, Apple Silicon host, translated x86-64 process.
- Bottle: `scratch/steam-check/data/Bottles/bottle_024F8C79-6160-438B-A421-D050569B8B47`.
- Configuration: 64-bit, automatic graphics, ESync.
- Harness: `scratch/steam-check/SteamCheck.swift`, compiled directly with the current WarpNestCore source. Uses BottleService, LibraryService, WineRuntimeAdapter, and ProcessSupervisor; this was not a click-through test of the SwiftUI installation workflow.
- The test metadata is separate from the normal WarpNest application library. The test bottle has not been registered in the app's main sidebar/library.

## Observations

1. Installer launched through LibraryService with `/S`, created Steam files, and exited with status 0.
2. First client launch through LibraryService stalled at 108 of 336,229 KB. A host HEAD request to one exact update URL returned HTTP 200. Captured a process stack sample. Root cause is not established.
3. Stopped only this test prefix and performed a control launch with Wine output redirected to a regular file. It downloaded 241,937 KB and completed its update at 22:04:47 IST.
4. Relaunched through LibraryService. A second update downloaded 240,218 KB and completed at 22:06:15 IST. Client build 1794424036 then verified its installation and initialized.
5. Steam's connectivity test reported Connected. CEF reported DXGI/GLES errors; Steam automatically disabled GPU acceleration at 22:06:34.
6. At 22:07:00–22:07:01, webhelper logged creation of `SP DesktopLoginWindow_uid0`, LoadEnd, and the window titled `Sign in to` becoming visible (`WasHidden 0`). This is log evidence, not visual verification. Computer-use tools could inspect WarpNest but could not attach to the Wine-hosted Steam application.
7. Stopped the dedicated test prefix and harness after collecting evidence. Preserved installation and logs.

## Evidence

Saved under `scratch/steam-check/`: installer and launch supervision logs, first-launch log, direct Wine log, bootstrap log, webhelper log, CEF log, connectivity log, Steam UI log, and process stack sample.

## Follow-up

Run an interactive sign-in and a small game through the app before claiming Steam/game compatibility. Investigate the first-launch stall and process supervision across Steam's self-update restarts; the successful comparison launch alone does not prove a WarpNest-specific cause. Validate the client UI with its automatic software-rendering fallback.
