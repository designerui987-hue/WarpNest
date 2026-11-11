# Third-Party Notices & Licensing

WarpNest interacts with and integrates several open-source software projects and specifications.

---

## 1. Wine (WineHQ)
- **License:** GNU Lesser General Public License (LGPL) v2.1 or later
- **Website:** https://www.winehq.org
- **Notes:** Used for Windows API translation on POSIX systems. WarpNest communicates with Wine through standard process invocation (`wine`, `wineboot`, `wineserver`) and does not link statically against Wine libraries.

---

## 2. DXVK
- **License:** zlib / libpng License
- **Website:** https://github.com/doitsujin/dxvk
- **Notes:** Translates Direct3D 9/10/11 graphics commands to Vulkan.

---

## 3. MoltenVK
- **License:** Apache License 2.0
- **Website:** https://github.com/KhronosGroup/MoltenVK
- **Notes:** Provides a Vulkan implementation on top of Apple's Metal graphics framework.

---

## 4. GStreamer
- **License:** GNU Lesser General Public License (LGPL) v2.1 or later
- **Website:** https://gstreamer.freedesktop.org
- **Notes:** Provides multimedia decoding and video/audio playback pipelines inside Wine prefixes.

---

## Proprietary Components Policy
WarpNest strictly excludes proprietary Apple Game Porting Toolkit evaluation binaries (such as `libd3dshared.dylib` and `D3DMetal.framework`) from its source distribution.
